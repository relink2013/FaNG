import Logging
import PostgresNIO

/// Schema migrations, applied in order at startup. Each runs once, in its own transaction.
public enum Migrations {
    /// The schema version once every migration is applied; other services wait for it before querying.
    public static var latest: Int { all.map(\.version).max() ?? 0 }

    static let all: [(version: Int, sql: [String])] = [
        (1, [
            """
            CREATE TABLE shares (
                name text PRIMARY KEY,
                path text NOT NULL,
                create_mask integer NOT NULL,
                directory_mask integer NOT NULL,
                updated timestamptz NOT NULL DEFAULT now()
            )
            """,
        ]),
        (2, [
            // Every change to an item takes the next number; a client's sync anchor is the last one it saw.
            "CREATE SEQUENCE change_seq",
            // Identifies this database, so a client notices when its anchors belong to another one.
            "CREATE TABLE server (epoch uuid NOT NULL)",
            "INSERT INTO server (epoch) VALUES (gen_random_uuid())",
            """
            CREATE TABLE items (
                id uuid PRIMARY KEY,
                share text NOT NULL,
                parent uuid,
                name text NOT NULL,
                path text NOT NULL,
                is_dir boolean NOT NULL,
                size bigint NOT NULL,
                mtime_ns bigint NOT NULL,
                inode bigint NOT NULL,
                content_version bigint NOT NULL DEFAULT 1,
                metadata_version bigint NOT NULL DEFAULT 1,
                deleted boolean NOT NULL DEFAULT false,
                seq bigint NOT NULL
            )
            """,
            "CREATE UNIQUE INDEX items_live_path ON items (share, path) WHERE NOT deleted",
            "CREATE INDEX items_children ON items (parent, name) WHERE NOT deleted",
            "CREATE INDEX items_changes ON items (share, seq)",
        ]),
        (3, [
            // Earlier contents of a file, kept as plain files in the share's .fang-versions folder.
            // A branch is a conflicting edit that didn't become the file.
            """
            CREATE TABLE versions (
                id bigserial PRIMARY KEY,
                item uuid NOT NULL,
                share text NOT NULL,
                path text NOT NULL,
                size bigint NOT NULL,
                mtime_ns bigint NOT NULL,
                content_version bigint NOT NULL,
                kind text NOT NULL CHECK (kind IN ('version', 'branch')),
                created timestamptz NOT NULL DEFAULT now()
            )
            """,
            "CREATE INDEX versions_item ON versions (item, id)",
        ]),
        (4, [
            // In the trash: the item (and what's below it) lives under .fang-trash; it remembers where it was.
            "ALTER TABLE items ADD COLUMN trashed boolean NOT NULL DEFAULT false",
            "ALTER TABLE items ADD COLUMN trashed_at timestamptz",
            "ALTER TABLE items ADD COLUMN original_path text",
            "CREATE INDEX items_trash ON items (share, trashed_at) WHERE trashed AND NOT deleted",
        ]),
        (5, [
            // One thumbnail per item, for one content version; a failure is remembered for that version.
            """
            CREATE TABLE thumbnails (
                item uuid PRIMARY KEY,
                content_version bigint NOT NULL,
                status text NOT NULL CHECK (status IN ('ready', 'failed')),
                source text,
                width integer,
                height integer,
                bytes integer,
                error text,
                updated timestamptz NOT NULL DEFAULT now()
            )
            """,
            // Thumbnails a client is waiting for: these go first.
            "CREATE TABLE thumbnail_wanted (item uuid PRIMARY KEY, requested timestamptz NOT NULL DEFAULT now())",
        ]),
        (6, [
            // Finder tags ("name\ncolor"), as read from the file's tag stream.
            "ALTER TABLE items ADD COLUMN tags text[] NOT NULL DEFAULT '{}'",
            // A branch stays open until the conflict is resolved; the device groups related conflicts.
            "ALTER TABLE versions ADD COLUMN resolved boolean NOT NULL DEFAULT false",
            "ALTER TABLE versions ADD COLUMN device text",
        ]),
        (7, [
            // Speed under load (a big copy): the latest change, path-prefix lookups (folder moves and
            // deletes, with LIKE 'prefix%'), and the thumbnail queue's extension test.
            "CREATE INDEX items_seq ON items (seq)",
            "CREATE INDEX items_path_like ON items (share, path text_pattern_ops) WHERE NOT deleted",
            "ALTER TABLE items ADD COLUMN ext text GENERATED ALWAYS AS (lower(substring(name from '\\.([^./]+)$'))) STORED",
            "CREATE INDEX items_media ON items (ext) WHERE NOT deleted AND NOT trashed AND NOT is_dir",
        ]),
        (8, [
            // Thumbnails of versions, made when a client asks (a version's contents never change).
            """
            CREATE TABLE version_thumbnails (
                version bigint PRIMARY KEY,
                status text NOT NULL CHECK (status IN ('ready', 'failed')),
                source text,
                width integer,
                height integer,
                bytes integer,
                error text,
                updated timestamptz NOT NULL DEFAULT now()
            )
            """,
            "CREATE TABLE version_thumbnail_wanted (version bigint PRIMARY KEY, requested timestamptz NOT NULL DEFAULT now())",
        ]),
        (9, [
            // An item a server copy is still making (job_state 'copying', with its progress in percent), or one
            // whose copy failed ('failed'). Such an item has nothing on disk at its path until the copy is done.
            "ALTER TABLE items ADD COLUMN job_state text CHECK (job_state IN ('copying', 'failed'))",
            "ALTER TABLE items ADD COLUMN progress integer",
            "CREATE INDEX items_jobs ON items (job_state) WHERE job_state IS NOT NULL",
        ]),
        (10, [
            // Why a copy failed, for the app's list of copies (a failure stays there until it's deleted).
            "ALTER TABLE items ADD COLUMN job_error text",
        ]),
        (11, [
            // Files a server copy made, with the original they came from and its content version at the time:
            // fang-thumbs links the original's thumbnail for them instead of making it again.
            """
            CREATE TABLE thumbnail_copies (
                item uuid PRIMARY KEY,
                source uuid NOT NULL,
                source_version bigint NOT NULL,
                created timestamptz NOT NULL DEFAULT now()
            )
            """,
        ]),
        (12, [
            // Client metadata kept as extended attributes (folder symbols and emoji, "Where from", …), as JSON.
            "ALTER TABLE items ADD COLUMN xattrs text NOT NULL DEFAULT ''",
        ]),
        (13, [
            // Thumbnails by contents: one file per distinct contents (a fingerprint of size and sampled bytes),
            // shared by every item and version with those contents, in any share or pool. `kind` leaves room
            // for other previews. Items and versions point at theirs; older thumbnails (no fingerprint) keep
            // their file per item.
            """
            CREATE TABLE thumbnail_blobs (
                fingerprint text NOT NULL,
                kind text NOT NULL,
                status text NOT NULL CHECK (status IN ('ready', 'failed')),
                source text,
                width integer,
                height integer,
                bytes integer,
                error text,
                created timestamptz NOT NULL DEFAULT now(),
                PRIMARY KEY (fingerprint, kind)
            )
            """,
            "ALTER TABLE thumbnails ADD COLUMN fingerprint text",
            "ALTER TABLE version_thumbnails ADD COLUMN fingerprint text",
            "CREATE INDEX thumbnails_fingerprint ON thumbnails (fingerprint) WHERE fingerprint IS NOT NULL",
            "CREATE INDEX version_thumbnails_fingerprint ON version_thumbnails (fingerprint) WHERE fingerprint IS NOT NULL",
        ]),
        (14, [
            // Retention of deleted items: the change number reached at each daily mark, so deleted rows older than
            // the retention can go, and the oldest change number a client's anchor may still start from.
            "CREATE TABLE change_marks (at timestamptz PRIMARY KEY DEFAULT now(), seq bigint NOT NULL)",
            "ALTER TABLE server ADD COLUMN pruned_below bigint NOT NULL DEFAULT 0",
            "CREATE INDEX items_deleted ON items (seq) WHERE deleted",
            "CREATE INDEX versions_created ON versions (created)",
        ]),
        (15, [
            // Permissions: who may read or write what (see AccessRules). Never written to the files.
            """
            CREATE TABLE acl_rules (
                share text NOT NULL,
                path text NOT NULL,
                principal text NOT NULL,
                access text NOT NULL CHECK (access IN ('none', 'read', 'write')),
                updated timestamptz NOT NULL DEFAULT now(),
                PRIMARY KEY (share, path, principal)
            )
            """,
            "ALTER TABLE server ADD COLUMN acl_version bigint NOT NULL DEFAULT 0",
        ]),
        (16, [
            // Closed by default: no rule means no access. Users that existed then were given their access once
            // (access_seeded); home-folder rules are kept by fang-storaged (origin 'home').
            "ALTER TABLE acl_rules ADD COLUMN origin text NOT NULL DEFAULT 'admin'",
            "ALTER TABLE server ADD COLUMN access_seeded boolean NOT NULL DEFAULT false",
        ]),
        (17, [
            // Shares taken out of the shares file whose records wait to be removed (see RemovedShare).
            "CREATE TABLE removed_shares (name text PRIMARY KEY, since timestamptz NOT NULL DEFAULT now())",
        ]),
        (18, [
            // Where each share was last served (fang-storaged): a removed share whose folder another share now covers
            // has its records removed at once.
            "CREATE TABLE share_paths (name text PRIMARY KEY, path text NOT NULL)",
            // The shares served until now (the API's table still lists them while this runs).
            "INSERT INTO share_paths (name, path) SELECT name, path FROM shares ON CONFLICT DO NOTHING",
        ]),
        (19, [
            // Settings an admin changes while the server runs (the server's public address, later OIDC), one JSON
            // value per key.
            "CREATE TABLE settings (key text PRIMARY KEY, value text NOT NULL, updated timestamptz NOT NULL DEFAULT now())",
        ]),
        (20, [
            // Accounts: a FaNG user with an ID that never changes (rules, shares and OIDC sign-ins will name it).
            // Kept in step with /config/users, where users are added and removed. Samba keeps the SMB password.
            """
            CREATE TABLE accounts (
                id uuid PRIMARY KEY,
                name text NOT NULL UNIQUE,
                display_name text,
                email text,
                oidc_issuer text,
                oidc_subject text,
                disabled boolean NOT NULL DEFAULT false,
                created timestamptz NOT NULL DEFAULT now()
            )
            """,
            "CREATE UNIQUE INDEX accounts_oidc ON accounts (oidc_issuer, oidc_subject) WHERE oidc_subject IS NOT NULL",
            // Groups of users, for permission rules ("group:<name>").
            "CREATE TABLE groups (id uuid PRIMARY KEY, name text NOT NULL, created timestamptz NOT NULL DEFAULT now())",
            "CREATE UNIQUE INDEX groups_name ON groups (lower(name))",
            """
            CREATE TABLE group_members (
                group_id uuid NOT NULL REFERENCES groups (id) ON DELETE CASCADE,
                account_id uuid NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
                PRIMARY KEY (group_id, account_id)
            )
            """,
            "CREATE INDEX group_members_account ON group_members (account_id)",
        ]),
    ]

    public static func apply(on client: PostgresClient, logger: Logger) async throws {
        // fang-api and fang-storaged both start here; one applies, the other waits for it.
        try await client.withConnection { connection in
            try await connection.query("SELECT pg_advisory_lock(\(lockKey))", logger: logger)
            do {
                try await applyAll(on: connection, logger: logger)
            } catch {
                _ = try? await connection.query("SELECT pg_advisory_unlock(\(lockKey))", logger: logger)
                throw error
            }
            try await connection.query("SELECT pg_advisory_unlock(\(lockKey))", logger: logger)
        }
    }

    private static let lockKey: Int64 = 0x6661_6E67  // "fang"

    private static func applyAll(on client: PostgresConnection, logger: Logger) async throws {
        try await client.query("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version integer PRIMARY KEY,
                applied timestamptz NOT NULL DEFAULT now()
            )
            """, logger: logger)
        var applied = Set<Int>()
        for try await version in try await client.query("SELECT version FROM schema_migrations", logger: logger).decode(Int.self) {
            applied.insert(version)
        }
        for migration in all where !applied.contains(migration.version) {
            try await client.query("BEGIN", logger: logger)
            do {
                for statement in migration.sql {
                    try await client.query(PostgresQuery(unsafeSQL: statement), logger: logger)
                }
                try await client.query("INSERT INTO schema_migrations (version) VALUES (\(migration.version))", logger: logger)
                try await client.query("COMMIT", logger: logger)
            } catch {
                _ = try? await client.query("ROLLBACK", logger: logger)
                throw error
            }
            logger.info("Applied migration \(migration.version)")
        }
    }
}

extension Share {
    /// Makes the shares table match the shares file.
    public static func sync(_ shares: [Share], on client: PostgresClient, logger: Logger) async throws {
        try await client.withTransaction(logger: logger) { connection in
            try await connection.query("DELETE FROM shares", logger: logger)
            for share in shares {
                try await connection.query("""
                    INSERT INTO shares (name, path, create_mask, directory_mask)
                    VALUES (\(share.name), \(share.path), \(share.createMask), \(share.directoryMask))
                    """, logger: logger)
            }
        }
    }
}
