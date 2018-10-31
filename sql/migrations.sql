This is not meant to be run directly.

-- migration #1
CREATE TABLE db_meta (key text PRIMARY KEY, value jsonb);
INSERT INTO db_meta (key, value) VALUES ('schema_version', '1'::jsonb);

-- migration #2
CREATE OR REPLACE VIEW current_takes AS
    SELECT * FROM (
         SELECT DISTINCT ON (member, team) t.*
           FROM takes t
       ORDER BY member, team, mtime DESC
    ) AS anon WHERE amount IS NOT NULL;
ALTER TABLE participants DROP COLUMN is_suspicious;

-- migration #3
ALTER TABLE paydays ADD COLUMN nusers bigint NOT NULL DEFAULT 0,
                    ADD COLUMN week_deposits numeric(35,2) NOT NULL DEFAULT 0,
                    ADD COLUMN week_withdrawals numeric(35,2) NOT NULL DEFAULT 0;
WITH week_exchanges AS (
         SELECT e.*, (
                    SELECT p.id
                      FROM paydays p
                     WHERE e.timestamp < p.ts_start
                  ORDER BY p.ts_start DESC
                     LIMIT 1
                ) AS payday_id
           FROM exchanges e
          WHERE status <> 'failed'
     )
UPDATE paydays p
   SET nusers = (
           SELECT count(*)
             FROM participants
            WHERE kind IN ('individual', 'organization')
              AND join_time < p.ts_start
              AND status = 'active'
       )
     , week_deposits = (
           SELECT COALESCE(sum(amount), 0)
             FROM week_exchanges
            WHERE payday_id = p.id
              AND amount > 0
       )
     , week_withdrawals = (
           SELECT COALESCE(-sum(amount), 0)
             FROM week_exchanges
            WHERE payday_id = p.id
              AND amount < 0
       );

-- migration #4
CREATE TABLE app_conf (key text PRIMARY KEY, value jsonb);

-- migration #5
UPDATE elsewhere
   SET avatar_url = regexp_replace(avatar_url,
          '^https://secure\.gravatar\.com/',
          'https://seccdn.libravatar.org/'
       )
 WHERE avatar_url LIKE '%//secure.gravatar.com/%';
UPDATE participants
   SET avatar_url = regexp_replace(avatar_url,
          '^https://secure\.gravatar\.com/',
          'https://seccdn.libravatar.org/'
       )
 WHERE avatar_url LIKE '%//secure.gravatar.com/%';
ALTER TABLE participants ADD COLUMN avatar_src text;
ALTER TABLE participants ADD COLUMN avatar_email text;

-- migration #6
ALTER TABLE exchanges ADD COLUMN vat numeric(35,2) NOT NULL DEFAULT 0;
ALTER TABLE exchanges ALTER COLUMN vat DROP DEFAULT;

-- migration #7
CREATE TABLE e2e_transfers
( id           bigserial      PRIMARY KEY
, origin       bigint         NOT NULL REFERENCES exchanges
, withdrawal   bigint         NOT NULL REFERENCES exchanges
, amount       numeric(35,2)  NOT NULL CHECK (amount > 0)
);
ALTER TABLE exchanges ADD CONSTRAINT exchanges_amount_check CHECK (amount <> 0);

-- migration #8
ALTER TABLE participants ADD COLUMN profile_nofollow boolean DEFAULT TRUE;

-- migration #9
CREATE OR REPLACE VIEW sponsors AS
    SELECT *
      FROM participants p
     WHERE status = 'active'
       AND kind = 'organization'
       AND giving > receiving
       AND giving >= 10
       AND NOT profile_nofollow;

-- migration #10
ALTER TABLE notification_queue ADD COLUMN is_new boolean NOT NULL DEFAULT TRUE;

-- migration #11
ALTER TYPE payment_net ADD VALUE 'mango-bw' BEFORE 'mango-cc';

-- migration #12
ALTER TABLE communities ADD COLUMN is_hidden boolean NOT NULL DEFAULT FALSE;

-- migration #13
ALTER TABLE participants ADD COLUMN profile_noindex boolean NOT NULL DEFAULT FALSE;
ALTER TABLE participants ADD COLUMN hide_from_lists boolean NOT NULL DEFAULT FALSE;

-- migration #14
DROP VIEW sponsors;
ALTER TABLE participants ADD COLUMN privileges int NOT NULL DEFAULT 0;
UPDATE participants SET privileges = 1 WHERE is_admin;
ALTER TABLE participants DROP COLUMN is_admin;
CREATE OR REPLACE VIEW sponsors AS
    SELECT *
      FROM participants p
     WHERE status = 'active'
       AND kind = 'organization'
       AND giving > receiving
       AND giving >= 10
       AND NOT profile_nofollow;
DELETE FROM app_conf WHERE key = 'cache_static';

-- migration #15
ALTER TABLE transfers ADD COLUMN error text;

-- migration #16
ALTER TABLE participants ADD COLUMN is_suspended boolean;

-- migration #17
ALTER TYPE transfer_context ADD VALUE 'refund';

-- migration #18
ALTER TABLE transfers ADD COLUMN refund_ref bigint REFERENCES transfers;
ALTER TABLE exchanges ADD COLUMN refund_ref bigint REFERENCES exchanges;

-- migration #19
ALTER TABLE participants DROP CONSTRAINT password_chk;

-- migration #20
ALTER TABLE transfers
    DROP CONSTRAINT team_chk,
    ADD CONSTRAINT team_chk CHECK (NOT (context='take' AND team IS NULL));

-- migration #21
CREATE TYPE donation_period AS ENUM ('weekly', 'monthly', 'yearly');
ALTER TABLE tips
    ADD COLUMN period donation_period,
    ADD COLUMN periodic_amount numeric(35,2);
UPDATE tips SET period = 'weekly', periodic_amount = amount;
ALTER TABLE tips
    ALTER COLUMN period SET NOT NULL,
    ALTER COLUMN periodic_amount SET NOT NULL;
CREATE OR REPLACE VIEW current_tips AS
    SELECT DISTINCT ON (tipper, tippee) *
      FROM tips
  ORDER BY tipper, tippee, mtime DESC;

-- migration #22
DELETE FROM notification_queue WHERE event IN ('income', 'low_balance');

-- migration #23
INSERT INTO app_conf (key, value) VALUES ('csp_extra', '""'::jsonb);

-- migration #24
DELETE FROM app_conf WHERE key in ('compress_assets', 'csp_extra');

-- migration #25
DROP VIEW sponsors;
ALTER TABLE participants
    ALTER COLUMN profile_noindex DROP DEFAULT,
    ALTER COLUMN profile_noindex SET DATA TYPE int USING (profile_noindex::int | 2),
    ALTER COLUMN profile_noindex SET DEFAULT 2;
ALTER TABLE participants
    ALTER COLUMN hide_from_lists DROP DEFAULT,
    ALTER COLUMN hide_from_lists SET DATA TYPE int USING (hide_from_lists::int),
    ALTER COLUMN hide_from_lists SET DEFAULT 0;
ALTER TABLE participants
    ALTER COLUMN hide_from_search DROP DEFAULT,
    ALTER COLUMN hide_from_search SET DATA TYPE int USING (hide_from_search::int),
    ALTER COLUMN hide_from_search SET DEFAULT 0;
UPDATE participants p
   SET hide_from_lists = c.is_hidden::int
  FROM communities c
 WHERE c.participant = p.id;
ALTER TABLE communities DROP COLUMN is_hidden;
CREATE OR REPLACE VIEW sponsors AS
    SELECT *
      FROM participants p
     WHERE status = 'active'
       AND kind = 'organization'
       AND giving > receiving
       AND giving >= 10
       AND hide_from_lists = 0
       AND profile_noindex = 0
    ;
UPDATE participants SET profile_nofollow = true;

-- migration #26
DROP TYPE community_with_participant CASCADE;
DROP TYPE elsewhere_with_participant CASCADE;
CREATE TYPE community_with_participant AS
( c communities
, p participants
);
CREATE FUNCTION load_participant_for_community (communities)
RETURNS community_with_participant
AS $$
    SELECT $1, p
      FROM participants p
     WHERE p.id = $1.participant;
$$ LANGUAGE SQL;
CREATE CAST (communities AS community_with_participant)
    WITH FUNCTION load_participant_for_community(communities);
CREATE TYPE elsewhere_with_participant AS
( e elsewhere
, p participants
);
CREATE FUNCTION load_participant_for_elsewhere (elsewhere)
RETURNS elsewhere_with_participant
AS $$
    SELECT $1, p
      FROM participants p
     WHERE p.id = $1.participant;
$$ LANGUAGE SQL;
CREATE CAST (elsewhere AS elsewhere_with_participant)
    WITH FUNCTION load_participant_for_elsewhere(elsewhere);

-- migration #27
ALTER TABLE paydays
    ADD COLUMN transfer_volume_refunded numeric(35,2),
    ADD COLUMN week_deposits_refunded numeric(35,2),
    ADD COLUMN week_withdrawals_refunded numeric(35,2);

-- migration #28
INSERT INTO app_conf (key, value) VALUES ('socket_timeout', '10.0'::jsonb);

-- migration #29
CREATE TABLE newsletters
( id              bigserial     PRIMARY KEY
, ctime           timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP
, sender          bigint        NOT NULL REFERENCES participants
);
CREATE TABLE newsletter_texts
( id              bigserial     PRIMARY KEY
, newsletter      bigint        NOT NULL REFERENCES newsletters
, lang            text          NOT NULL
, subject         text          NOT NULL CHECK (subject <> '')
, body            text          NOT NULL CHECK (body <> '')
, ctime           timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP
, scheduled_for   timestamptz
, sent_at         timestamptz
, sent_count      int
, UNIQUE (newsletter, lang)
);
CREATE INDEX newsletter_texts_not_sent_idx
          ON newsletter_texts (scheduled_for ASC)
       WHERE sent_at IS NULL AND scheduled_for IS NOT NULL;
CREATE TABLE subscriptions
( id            bigserial      PRIMARY KEY
, publisher     bigint         NOT NULL REFERENCES participants
, subscriber    bigint         NOT NULL REFERENCES participants
, ctime         timestamptz    NOT NULL DEFAULT CURRENT_TIMESTAMP
, mtime         timestamptz    NOT NULL DEFAULT CURRENT_TIMESTAMP
, is_on         boolean        NOT NULL
, token         text
, UNIQUE (publisher, subscriber)
);
LOCK TABLE community_subscriptions IN EXCLUSIVE MODE;
INSERT INTO subscriptions (publisher, subscriber, ctime, mtime, is_on)
     SELECT c.participant, cs.participant, cs.ctime, cs.mtime, cs.is_on
       FROM community_subscriptions cs
       JOIN communities c ON c.id = cs.community
   ORDER BY cs.ctime ASC;
DROP TABLE community_subscriptions;
DROP FUNCTION IF EXISTS update_community_nsubscribers();
ALTER TABLE participants ADD COLUMN nsubscribers int NOT NULL DEFAULT 0;
LOCK TABLE communities IN EXCLUSIVE MODE;
UPDATE participants p
   SET nsubscribers = c.nsubscribers
  FROM communities c
 WHERE c.participant = p.id
   AND c.nsubscribers <> p.nsubscribers;
ALTER TABLE communities DROP COLUMN nsubscribers;
CREATE OR REPLACE FUNCTION update_community_nmembers() RETURNS trigger AS $$
    DECLARE
        old_is_on boolean = (CASE WHEN TG_OP = 'INSERT' THEN FALSE ELSE OLD.is_on END);
        new_is_on boolean = (CASE WHEN TG_OP = 'DELETE' THEN FALSE ELSE NEW.is_on END);
        delta int = CASE WHEN new_is_on THEN 1 ELSE -1 END;
        rec record;
    BEGIN
        rec := (CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
        IF (new_is_on = old_is_on) THEN
            RETURN (CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE rec END);
        END IF;
        UPDATE communities
           SET nmembers = nmembers + delta
         WHERE id = rec.community;
        RETURN rec;
    END;
$$ LANGUAGE plpgsql;
CREATE OR REPLACE FUNCTION update_nsubscribers() RETURNS trigger AS $$
    DECLARE
        old_is_on boolean = (CASE WHEN TG_OP = 'INSERT' THEN FALSE ELSE OLD.is_on END);
        new_is_on boolean = (CASE WHEN TG_OP = 'DELETE' THEN FALSE ELSE NEW.is_on END);
        delta int = CASE WHEN new_is_on THEN 1 ELSE -1 END;
        rec record;
    BEGIN
        rec := (CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
        IF (new_is_on = old_is_on) THEN
            RETURN (CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE rec END);
        END IF;
        UPDATE participants
           SET nsubscribers = nsubscribers + delta
         WHERE id = rec.publisher;
        RETURN rec;
    END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER update_nsubscribers
    BEFORE INSERT OR UPDATE OR DELETE ON subscriptions
    FOR EACH ROW
    EXECUTE PROCEDURE update_nsubscribers();

-- migration #30
ALTER TYPE transfer_context ADD VALUE 'expense';

-- migration #31
CREATE TYPE invoice_nature AS ENUM ('expense');
CREATE TYPE invoice_status AS ENUM
    ('pre', 'canceled', 'new', 'retracted', 'accepted', 'paid', 'rejected');
CREATE TABLE invoices
( id            serial            PRIMARY KEY
, ctime         timestamptz       NOT NULL DEFAULT CURRENT_TIMESTAMP
, sender        bigint            NOT NULL REFERENCES participants
, addressee     bigint            NOT NULL REFERENCES participants
, nature        invoice_nature    NOT NULL
, amount        numeric(35,2)     NOT NULL CHECK (amount > 0)
, description   text              NOT NULL
, details       text
, documents     jsonb             NOT NULL
, status        invoice_status    NOT NULL
);
CREATE TABLE invoice_events
( id            serial            PRIMARY KEY
, invoice       int               NOT NULL REFERENCES invoices
, participant   bigint            NOT NULL REFERENCES participants
, ts            timestamptz       NOT NULL DEFAULT CURRENT_TIMESTAMP
, status        invoice_status    NOT NULL
, message       text
);
ALTER TABLE participants ADD COLUMN allow_invoices boolean;
ALTER TABLE transfers
    ADD COLUMN invoice int REFERENCES invoices,
    ADD CONSTRAINT expense_chk CHECK (NOT (context='expense' AND invoice IS NULL));
INSERT INTO app_conf VALUES
    ('s3_endpoint', '""'::jsonb),
    ('s3_public_access_key', '""'::jsonb),
    ('s3_secret_key', '""'::jsonb),
    ('s3_region', '"eu-west-1"'::jsonb);

-- migration #32
ALTER TABLE cash_bundles
    ADD COLUMN withdrawal int REFERENCES exchanges,
    ALTER COLUMN owner DROP NOT NULL;
INSERT INTO cash_bundles
            (owner, origin, amount, ts)
     SELECT NULL, e2e.origin, e2e.amount
          , (SELECT e.timestamp FROM exchanges e WHERE e.id = e2e.origin)
       FROM e2e_transfers e2e;
DROP TABLE e2e_transfers;

-- migration #33
ALTER TABLE cash_bundles ADD CONSTRAINT in_or_out CHECK ((owner IS NULL) <> (withdrawal IS NULL));

-- migration #34
ALTER TABLE participants DROP CONSTRAINT participants_email_key;
CREATE UNIQUE INDEX participants_email_key ON participants (lower(email));
ALTER TABLE emails DROP CONSTRAINT emails_address_verified_key;
CREATE UNIQUE INDEX emails_address_verified_key ON emails (lower(address), verified);

-- migration #35
ALTER TABLE elsewhere ADD COLUMN domain text NOT NULL DEFAULT '';
ALTER TABLE elsewhere ALTER COLUMN domain DROP DEFAULT;
DROP INDEX elsewhere_lower_platform_idx;
CREATE UNIQUE INDEX elsewhere_user_name_key ON elsewhere (lower(user_name), platform, domain);
ALTER TABLE elsewhere DROP CONSTRAINT elsewhere_platform_user_id_key;
CREATE UNIQUE INDEX elsewhere_user_id_key ON elsewhere (platform, domain, user_id);
CREATE TABLE oauth_apps
( platform   text          NOT NULL
, domain     text          NOT NULL
, key        text          NOT NULL
, secret     text          NOT NULL
, ctime      timestamptz   NOT NULL DEFAULT CURRENT_TIMESTAMP
, UNIQUE (platform, domain, key)
);
INSERT INTO app_conf (key, value) VALUES
    ('app_name', '"Liberapay Dev"'::jsonb);

-- migration #36
ALTER TABLE elsewhere
    ALTER COLUMN user_id DROP NOT NULL,
    ADD CONSTRAINT user_id_chk CHECK (user_id IS NOT NULL OR domain <> '' AND user_name IS NOT NULL);

-- migration #37
ALTER TABLE participants ADD COLUMN throttle_takes boolean NOT NULL DEFAULT TRUE;

-- migration #38
CREATE TABLE repositories
( id                    bigserial       PRIMARY KEY
, platform              text            NOT NULL
, remote_id             text            NOT NULL
, owner_id              text            NOT NULL
, name                  text            NOT NULL
, slug                  text            NOT NULL
, description           text
, last_update           timestamptz     NOT NULL
, is_fork               boolean
, stars_count           int
, extra_info            json
, info_fetched_at       timestamptz     NOT NULL DEFAULT now()
, participant           bigint          REFERENCES participants
, show_on_profile       boolean         NOT NULL DEFAULT FALSE
, UNIQUE (platform, remote_id)
, UNIQUE (platform, slug)
);
CREATE INDEX repositories_trgm_idx ON repositories
    USING gist(name gist_trgm_ops);
INSERT INTO app_conf (key, value) VALUES
    ('refetch_repos_every', '60'::jsonb);

-- migration #39
ALTER TABLE paydays
    ADD COLUMN stage int,
    ALTER COLUMN stage SET DEFAULT 1;
INSERT INTO app_conf VALUES
    ('s3_payday_logs_bucket', '""'::jsonb),
    ('bot_github_username', '"liberapay-bot"'::jsonb),
    ('bot_github_token', '""'::jsonb),
    ('payday_repo', '"liberapay-bot/test"'::jsonb),
    ('payday_label', '"Payday"'::jsonb);
ALTER TABLE paydays ADD COLUMN public_log text;
UPDATE paydays SET public_log = '';
ALTER TABLE paydays ALTER COLUMN public_log SET NOT NULL;
ALTER TABLE paydays
    ALTER COLUMN ts_start DROP DEFAULT,
    ALTER COLUMN ts_start DROP NOT NULL;

-- migration #40
ALTER TABLE cash_bundles ADD COLUMN disputed boolean;
ALTER TYPE transfer_context ADD VALUE IF NOT EXISTS 'chargeback';
CREATE TABLE disputes
( id              bigint          PRIMARY KEY
, creation_date   timestamptz     NOT NULL
, type            text            NOT NULL
, amount          numeric(35,2)   NOT NULL
, status          text            NOT NULL
, result_code     text
, exchange_id     int             NOT NULL REFERENCES exchanges
, participant     bigint          NOT NULL REFERENCES participants
);
CREATE TYPE debt_status AS ENUM ('due', 'paid', 'void');
CREATE TABLE debts
( id              serial          PRIMARY KEY
, debtor          bigint          NOT NULL REFERENCES participants
, creditor        bigint          NOT NULL REFERENCES participants
, amount          numeric(35,2)   NOT NULL
, origin          int             NOT NULL REFERENCES exchanges
, status          debt_status     NOT NULL
, settlement      int             REFERENCES transfers
, CONSTRAINT settlement_chk CHECK ((status = 'paid') = (settlement IS NOT NULL))
);
ALTER TYPE transfer_context ADD VALUE IF NOT EXISTS 'debt';
ALTER TABLE cash_bundles ADD COLUMN locked_for int REFERENCES transfers;
CREATE OR REPLACE FUNCTION get_username(p_id bigint) RETURNS text
AS $$
    SELECT username FROM participants WHERE id = p_id;
$$ LANGUAGE sql;

-- migration #41
ALTER TYPE transfer_context ADD VALUE IF NOT EXISTS 'account-switch';
ALTER TABLE transfers
    DROP CONSTRAINT self_chk,
    ADD CONSTRAINT self_chk CHECK ((tipper <> tippee) = (context <> 'account-switch'));
CREATE TABLE mangopay_users
( id            text     PRIMARY KEY
, participant   bigint   NOT NULL REFERENCES participants
);
CREATE OR REPLACE FUNCTION upsert_mangopay_user_id() RETURNS trigger AS $$
    BEGIN
        INSERT INTO mangopay_users
                    (id, participant)
             VALUES (NEW.mangopay_user_id, NEW.id)
        ON CONFLICT (id) DO NOTHING;
        RETURN NULL;
    END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER upsert_mangopay_user_id
    AFTER INSERT OR UPDATE OF mangopay_user_id ON participants
    FOR EACH ROW WHEN (NEW.mangopay_user_id IS NOT NULL)
    EXECUTE PROCEDURE upsert_mangopay_user_id();
INSERT INTO mangopay_users
            (id, participant)
     SELECT p.mangopay_user_id, p.id
       FROM participants p
      WHERE p.mangopay_user_id IS NOT NULL;
ALTER TABLE transfers
    ADD COLUMN wallet_from text,
    ADD COLUMN wallet_to text;
UPDATE transfers t
   SET wallet_from = (SELECT p.mangopay_wallet_id FROM participants p WHERE p.id = t.tipper)
     , wallet_to = (SELECT p.mangopay_wallet_id FROM participants p WHERE p.id = t.tippee)
     ;
ALTER TABLE transfers
    ALTER COLUMN wallet_from SET NOT NULL,
    ALTER COLUMN wallet_to SET NOT NULL,
    ADD CONSTRAINT wallets_chk CHECK (wallet_from <> wallet_to);
ALTER TABLE exchange_routes ADD COLUMN remote_user_id text;
UPDATE exchange_routes r SET remote_user_id = (SELECT p.mangopay_user_id FROM participants p WHERE p.id = r.participant);
ALTER TABLE exchange_routes ALTER COLUMN remote_user_id SET NOT NULL;
DROP VIEW current_exchange_routes CASCADE;
CREATE VIEW current_exchange_routes AS
    SELECT DISTINCT ON (participant, network) *
      FROM exchange_routes
  ORDER BY participant, network, id DESC;
CREATE CAST (current_exchange_routes AS exchange_routes) WITH INOUT;
ALTER TABLE cash_bundles ADD COLUMN wallet_id text;
UPDATE cash_bundles b
   SET wallet_id = (SELECT p.mangopay_wallet_id FROM participants p WHERE p.id = b.owner)
 WHERE owner IS NOT NULL;
ALTER TABLE cash_bundles
    ALTER COLUMN wallet_id DROP DEFAULT,
    ADD CONSTRAINT wallet_chk CHECK ((wallet_id IS NULL) = (owner IS NULL));
ALTER TABLE exchanges ADD COLUMN wallet_id text;
UPDATE exchanges e
   SET wallet_id = (SELECT p.mangopay_wallet_id FROM participants p WHERE p.id = e.participant);
ALTER TABLE exchanges
    ALTER COLUMN wallet_id DROP DEFAULT,
    ALTER COLUMN wallet_id SET NOT NULL;

-- migration #42
DELETE FROM app_conf WHERE key = 'update_global_stats_every';

-- migration #43
ALTER TABLE statements
    ADD COLUMN id bigserial PRIMARY KEY,
    ADD COLUMN ctime timestamptz NOT NULL DEFAULT '1970-01-01T00:00:00+00'::timestamptz,
    ADD COLUMN mtime timestamptz NOT NULL DEFAULT '1970-01-01T00:00:00+00'::timestamptz;
ALTER TABLE statements
    ALTER COLUMN ctime DROP DEFAULT,
    ALTER COLUMN mtime DROP DEFAULT;

-- migration #44
ALTER TABLE notification_queue ADD COLUMN ts timestamptz;
ALTER TABLE notification_queue ALTER COLUMN ts SET DEFAULT now();

-- migration #45
INSERT INTO app_conf (key, value) VALUES
    ('twitch_id', '"9ro3g4slh0de5yijy6rqb2p0jgd7hi"'::jsonb),
    ('twitch_secret', '"o090sc7828d7gljtrqc5n4vcpx3bfx"'::jsonb);

-- migration #46
ALTER TABLE notification_queue
    ADD COLUMN email boolean NOT NULL DEFAULT FALSE,
    ADD COLUMN web boolean NOT NULL DEFAULT TRUE,
    ADD CONSTRAINT destination_chk CHECK (email OR web),
    ADD COLUMN email_sent boolean;
ALTER TABLE notification_queue RENAME TO notifications;
CREATE UNIQUE INDEX queued_emails_idx ON notifications (id ASC)
    WHERE (email AND email_sent IS NOT true);
ALTER TABLE notifications
    ALTER COLUMN email DROP DEFAULT,
    ALTER COLUMN web DROP DEFAULT;
DROP TABLE email_queue;

-- migration #47
DROP VIEW current_exchange_routes CASCADE;
ALTER TABLE exchange_routes ADD COLUMN ctime timestamptz;
UPDATE exchange_routes r
       SET ctime = (
               SELECT min(e.timestamp)
                 FROM exchanges e
                WHERE e.route = r.id
           )
     WHERE ctime IS NULL;
ALTER TABLE exchange_routes ALTER COLUMN ctime SET DEFAULT now();

-- migration #48
ALTER TABLE exchange_routes ADD COLUMN mandate text CHECK (mandate <> '');
ALTER TYPE exchange_status ADD VALUE IF NOT EXISTS 'pre-mandate';
INSERT INTO app_conf (key, value) VALUES
    ('show_sandbox_warning', 'true'::jsonb);

-- migration #49
ALTER TABLE exchanges ADD COLUMN remote_id text;
ALTER TABLE exchanges
    ADD CONSTRAINT remote_id_null_chk CHECK ((status::text LIKE 'pre%') = (remote_id IS NULL)),
    ADD CONSTRAINT remote_id_empty_chk CHECK (NOT (status <> 'failed' AND remote_id = ''));

-- migration #50
CREATE UNLOGGED TABLE rate_limiting
( key       text          PRIMARY KEY
, counter   int           NOT NULL
, ts        timestamptz   NOT NULL
);
CREATE OR REPLACE FUNCTION compute_leak(cap int, period float, last_leak timestamptz) RETURNS int AS $$
    SELECT trunc(cap * extract(epoch FROM current_timestamp - last_leak) / period)::int;
$$ LANGUAGE sql STABLE;
CREATE OR REPLACE FUNCTION hit_rate_limit(key text, cap int, period float) RETURNS int AS $$
    INSERT INTO rate_limiting AS r
                (key, counter, ts)
         VALUES (key, 1, current_timestamp)
    ON CONFLICT (key) DO UPDATE
            SET counter = r.counter + 1 - least(compute_leak(cap, period, r.ts), r.counter)
              , ts = current_timestamp
          WHERE (r.counter - compute_leak(cap, period, r.ts)) < cap
      RETURNING cap - counter;
$$ LANGUAGE sql;
CREATE OR REPLACE FUNCTION clean_up_counters(pattern text, period float) RETURNS bigint AS $$
    WITH deleted AS (
        DELETE FROM rate_limiting
              WHERE key LIKE pattern
                AND ts < (current_timestamp - make_interval(secs => period))
          RETURNING 1
    ) SELECT count(*) FROM deleted;
$$ LANGUAGE sql;
INSERT INTO app_conf (key, value) VALUES
    ('clean_up_counters_every', '3600'::jsonb),
    ('trusted_proxies', '[]'::jsonb);

-- migration #51
CREATE TABLE redirections
( from_prefix   text          PRIMARY KEY
, to_prefix     text          NOT NULL
, ctime         timestamptz   NOT NULL DEFAULT now()
, mtime         timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX redirections_to_prefix_idx ON redirections (to_prefix);

-- migration #52
ALTER TYPE stmt_type ADD VALUE IF NOT EXISTS 'summary';

-- migration #53
ALTER TABLE takes ADD COLUMN actual_amount numeric(35,2);
ALTER TABLE participants
    ADD COLUMN nteampatrons int NOT NULL DEFAULT 0,
    ADD COLUMN leftover numeric(35,2) NOT NULL DEFAULT 0 CHECK (leftover >= 0),
    ADD CONSTRAINT receiving_chk CHECK (receiving >= 0),
    ADD CONSTRAINT taking_chk CHECK (taking >= 0);
CREATE OR REPLACE VIEW current_takes AS
    SELECT * FROM (
         SELECT DISTINCT ON (member, team) t.*
           FROM takes t
       ORDER BY member, team, mtime DESC
    ) AS anon WHERE amount IS NOT NULL;
INSERT INTO app_conf VALUES ('update_cached_amounts_every', '86400'::jsonb);
ALTER TABLE takes ADD CONSTRAINT null_amounts_chk CHECK ((actual_amount IS NULL) = (amount IS NULL));

-- migration #54
CREATE TYPE currency AS ENUM ('EUR', 'USD');
CREATE TYPE currency_amount AS (amount numeric, currency currency);
CREATE FUNCTION currency_amount_add(currency_amount, currency_amount)
RETURNS currency_amount AS $$
    BEGIN
        IF ($1.currency <> $2.currency) THEN
            RAISE 'currency mistmatch: % != %', $1.currency, $2.currency;
        END IF;
        RETURN ($1.amount + $2.amount, $1.currency);
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR + (
    leftarg = currency_amount,
    rightarg = currency_amount,
    procedure = currency_amount_add,
    commutator = +
);
CREATE FUNCTION currency_amount_sub(currency_amount, currency_amount)
RETURNS currency_amount AS $$
    BEGIN
        IF ($1.currency <> $2.currency) THEN
            RAISE 'currency mistmatch: % != %', $1.currency, $2.currency;
        END IF;
        RETURN ($1.amount - $2.amount, $1.currency);
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR - (
    leftarg = currency_amount,
    rightarg = currency_amount,
    procedure = currency_amount_sub
);
CREATE FUNCTION currency_amount_neg(currency_amount)
RETURNS currency_amount AS $$
    BEGIN RETURN (-$1.amount, $1.currency); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR - (
    rightarg = currency_amount,
    procedure = currency_amount_neg
);
CREATE FUNCTION currency_amount_mul(currency_amount, numeric)
RETURNS currency_amount AS $$
    BEGIN
        RETURN ($1.amount * $2, $1.currency);
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR * (
    leftarg = currency_amount,
    rightarg = numeric,
    procedure = currency_amount_mul,
    commutator = *
);
CREATE AGGREGATE sum(currency_amount) (
    sfunc = currency_amount_add,
    stype = currency_amount
);
CREATE FUNCTION get_currency(currency_amount) RETURNS currency AS $$
    BEGIN RETURN $1.currency; END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE CAST (currency_amount as currency) WITH FUNCTION get_currency(currency_amount);
CREATE FUNCTION zero(currency) RETURNS currency_amount AS $$
    BEGIN RETURN ('0.00'::numeric, $1); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE FUNCTION zero(currency_amount) RETURNS currency_amount AS $$
    BEGIN RETURN ('0.00'::numeric, $1.currency); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE FUNCTION currency_amount_eq(currency_amount, currency_amount)
RETURNS boolean AS $$
    BEGIN RETURN ($1.currency = $2.currency AND $1.amount = $2.amount); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR = (
    leftarg = currency_amount,
    rightarg = currency_amount,
    procedure = currency_amount_eq,
    commutator = =
);
CREATE FUNCTION currency_amount_ne(currency_amount, currency_amount)
RETURNS boolean AS $$
    BEGIN RETURN ($1.currency <> $2.currency OR $1.amount <> $2.amount); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR <> (
    leftarg = currency_amount,
    rightarg = currency_amount,
    procedure = currency_amount_ne,
    commutator = <>
);
CREATE FUNCTION currency_amount_gt(currency_amount, currency_amount)
RETURNS boolean AS $$
    BEGIN
        IF ($1.currency <> $2.currency) THEN
            RAISE 'currency mistmatch: % != %', $1.currency, $2.currency;
        END IF;
        RETURN ($1.amount > $2.amount);
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR > (
    leftarg = currency_amount,
    rightarg = currency_amount,
    procedure = currency_amount_gt,
    commutator = <,
    negator = <=
);
CREATE FUNCTION currency_amount_gte(currency_amount, currency_amount)
RETURNS boolean AS $$
    BEGIN
        IF ($1.currency <> $2.currency) THEN
            RAISE 'currency mistmatch: % != %', $1.currency, $2.currency;
        END IF;
        RETURN ($1.amount >= $2.amount);
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR >= (
    leftarg = currency_amount,
    rightarg = currency_amount,
    procedure = currency_amount_gte,
    commutator = <=,
    negator = <
);
CREATE FUNCTION currency_amount_lt(currency_amount, currency_amount)
RETURNS boolean AS $$
    BEGIN
        IF ($1.currency <> $2.currency) THEN
            RAISE 'currency mistmatch: % != %', $1.currency, $2.currency;
        END IF;
        RETURN ($1.amount < $2.amount);
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR < (
    leftarg = currency_amount,
    rightarg = currency_amount,
    procedure = currency_amount_lt,
    commutator = >,
    negator = >=
);
CREATE FUNCTION currency_amount_lte(currency_amount, currency_amount)
RETURNS boolean AS $$
    BEGIN
        IF ($1.currency <> $2.currency) THEN
            RAISE 'currency mistmatch: % != %', $1.currency, $2.currency;
        END IF;
        RETURN ($1.amount <= $2.amount);
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR <= (
    leftarg = currency_amount,
    rightarg = currency_amount,
    procedure = currency_amount_lte,
    commutator = >=,
    negator = >
);
CREATE FUNCTION currency_amount_eq_numeric(currency_amount, numeric)
RETURNS boolean AS $$
    BEGIN RETURN ($1.amount = $2); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR = (
    leftarg = currency_amount,
    rightarg = numeric,
    procedure = currency_amount_eq_numeric,
    commutator = =
);
CREATE FUNCTION currency_amount_ne_numeric(currency_amount, numeric)
RETURNS boolean AS $$
    BEGIN RETURN ($1.amount <> $2); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR <> (
    leftarg = currency_amount,
    rightarg = numeric,
    procedure = currency_amount_ne_numeric,
    commutator = <>
);
CREATE FUNCTION currency_amount_gt_numeric(currency_amount, numeric)
RETURNS boolean AS $$
    BEGIN RETURN ($1.amount > $2); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR > (
    leftarg = currency_amount,
    rightarg = numeric,
    procedure = currency_amount_gt_numeric,
    commutator = <,
    negator = <=
);
CREATE FUNCTION currency_amount_gte_numeric(currency_amount, numeric)
RETURNS boolean AS $$
    BEGIN RETURN ($1.amount >= $2); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR >= (
    leftarg = currency_amount,
    rightarg = numeric,
    procedure = currency_amount_gte_numeric,
    commutator = <=,
    negator = <
);
CREATE FUNCTION currency_amount_lt_numeric(currency_amount, numeric)
RETURNS boolean AS $$
    BEGIN RETURN ($1.amount < $2); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR < (
    leftarg = currency_amount,
    rightarg = numeric,
    procedure = currency_amount_lt_numeric,
    commutator = >,
    negator = >=
);
CREATE FUNCTION currency_amount_lte_numeric(currency_amount, numeric)
RETURNS boolean AS $$
    BEGIN RETURN ($1.amount <= $2); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR <= (
    leftarg = currency_amount,
    rightarg = numeric,
    procedure = currency_amount_lte_numeric,
    commutator = >=,
    negator = >
);
CREATE TYPE currency_basket AS (EUR numeric, USD numeric);
CREATE FUNCTION currency_basket_add(currency_basket, currency_amount)
RETURNS currency_basket AS $$
    BEGIN
        IF ($2.currency = 'EUR') THEN
            RETURN ($1.EUR + $2.amount, $1.USD);
        ELSIF ($2.currency = 'USD') THEN
            RETURN ($1.EUR, $1.USD + $2.amount);
        ELSE
            RAISE 'unknown currency %', $2.currency;
        END IF;
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR + (
    leftarg = currency_basket,
    rightarg = currency_amount,
    procedure = currency_basket_add,
    commutator = +
);
CREATE FUNCTION currency_basket_add(currency_basket, currency_basket)
RETURNS currency_basket AS $$
    BEGIN RETURN ($1.EUR + $2.EUR, $1.USD + $2.USD); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR + (
    leftarg = currency_basket,
    rightarg = currency_basket,
    procedure = currency_basket_add,
    commutator = +
);
CREATE FUNCTION currency_basket_sub(currency_basket, currency_amount)
RETURNS currency_basket AS $$
    BEGIN
        IF ($2.currency = 'EUR') THEN
            RETURN ($1.EUR - $2.amount, $1.USD);
        ELSIF ($2.currency = 'USD') THEN
            RETURN ($1.EUR, $1.USD - $2.amount);
        ELSE
            RAISE 'unknown currency %', $2.currency;
        END IF;
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR - (
    leftarg = currency_basket,
    rightarg = currency_amount,
    procedure = currency_basket_sub
);
CREATE FUNCTION currency_basket_sub(currency_basket, currency_basket)
RETURNS currency_basket AS $$
    BEGIN RETURN ($1.EUR - $2.EUR, $1.USD - $2.USD); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR - (
    leftarg = currency_basket,
    rightarg = currency_basket,
    procedure = currency_basket_sub
);
CREATE FUNCTION currency_basket_contains(currency_basket, currency_amount)
RETURNS boolean AS $$
    BEGIN
        IF ($2.currency = 'EUR') THEN
            RETURN ($1.EUR >= $2.amount);
        ELSIF ($2.currency = 'USD') THEN
            RETURN ($1.USD >= $2.amount);
        ELSE
            RAISE 'unknown currency %', $2.currency;
        END IF;
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR >= (
    leftarg = currency_basket,
    rightarg = currency_amount,
    procedure = currency_basket_contains
);
CREATE AGGREGATE basket_sum(currency_amount) (
    sfunc = currency_basket_add,
    stype = currency_basket,
    initcond = '(0.00,0.00)'
);
CREATE TABLE currency_exchange_rates
( source_currency   currency   NOT NULL
, target_currency   currency   NOT NULL
, rate              numeric    NOT NULL
, UNIQUE (source_currency, target_currency)
);
CREATE FUNCTION convert(currency_amount, currency) RETURNS currency_amount AS $$
    DECLARE
        rate numeric;
    BEGIN
        IF ($1.currency = $2) THEN RETURN $1; END IF;
        rate := (
            SELECT r.rate
              FROM currency_exchange_rates r
             WHERE r.source_currency = $1.currency
        );
        IF (rate IS NULL) THEN
            RAISE 'missing exchange rate %->%', $1.currency, $2;
        END IF;
        RETURN ($1.amount / rate, $2);
    END;
$$ LANGUAGE plpgsql STRICT;
CREATE FUNCTION currency_amount_fuzzy_sum_sfunc(
    currency_amount, currency_amount, currency
) RETURNS currency_amount AS $$
    BEGIN RETURN ($1.amount + (convert($2, $3)).amount, $3); END;
$$ LANGUAGE plpgsql STRICT;
CREATE AGGREGATE sum(currency_amount, currency) (
    sfunc = currency_amount_fuzzy_sum_sfunc,
    stype = currency_amount,
    initcond = '(0,)'
);
CREATE TYPE currency_amount_fuzzy_avg_state AS (
    _sum numeric, _count int, target currency
);
CREATE FUNCTION currency_amount_fuzzy_avg_sfunc(
    currency_amount_fuzzy_avg_state, currency_amount, currency
) RETURNS currency_amount_fuzzy_avg_state AS $$
    BEGIN
        IF ($2.currency = $3) THEN
            RETURN ($1._sum + $2.amount, $1._count + 1, $3);
        END IF;
        RETURN ($1._sum + (convert($2, $3)).amount, $1._count + 1, $3);
    END;
$$ LANGUAGE plpgsql STRICT;
CREATE FUNCTION currency_amount_fuzzy_avg_ffunc(currency_amount_fuzzy_avg_state)
RETURNS currency_amount AS $$
    BEGIN RETURN ((CASE WHEN $1._count = 0 THEN 0 ELSE $1._sum / $1._count END), $1.target); END;
$$ LANGUAGE plpgsql STRICT;
CREATE AGGREGATE avg(currency_amount, currency) (
    sfunc = currency_amount_fuzzy_avg_sfunc,
    finalfunc = currency_amount_fuzzy_avg_ffunc,
    stype = currency_amount_fuzzy_avg_state,
    initcond = '(0,0,)'
);
ALTER TABLE participants ADD COLUMN main_currency currency NOT NULL DEFAULT 'EUR';
ALTER TABLE participants ADD COLUMN accept_all_currencies boolean;
UPDATE participants
   SET accept_all_currencies = true
 WHERE status = 'stub';
ALTER TABLE cash_bundles ALTER COLUMN amount TYPE currency_amount USING (amount, 'EUR');
ALTER TABLE debts ALTER COLUMN amount TYPE currency_amount USING (amount, 'EUR');
ALTER TABLE disputes ALTER COLUMN amount TYPE currency_amount USING (amount, 'EUR');
ALTER TABLE exchanges ALTER COLUMN amount TYPE currency_amount USING (amount, 'EUR');
ALTER TABLE exchanges ALTER COLUMN fee TYPE currency_amount USING (fee, 'EUR');
ALTER TABLE exchanges ALTER COLUMN vat TYPE currency_amount USING (vat, 'EUR');
ALTER TABLE invoices ALTER COLUMN amount TYPE currency_amount USING (amount, 'EUR');
ALTER TABLE transfers ALTER COLUMN amount TYPE currency_amount USING (amount, 'EUR');
DROP VIEW current_tips;
ALTER TABLE tips ALTER COLUMN amount TYPE currency_amount USING (amount, 'EUR');
ALTER TABLE tips ALTER COLUMN periodic_amount TYPE currency_amount USING (periodic_amount, 'EUR');
CREATE VIEW current_tips AS
        SELECT DISTINCT ON (tipper, tippee) *
          FROM tips
      ORDER BY tipper, tippee, mtime DESC;
CREATE TABLE wallets
    ( remote_id         text              NOT NULL UNIQUE
    , balance           currency_amount   NOT NULL CHECK (balance >= 0)
    , owner             bigint            NOT NULL REFERENCES participants
    , remote_owner_id   text              NOT NULL
    , is_current        boolean           DEFAULT TRUE
    );
CREATE UNIQUE INDEX ON wallets (owner, (balance::currency), is_current);
CREATE UNIQUE INDEX ON wallets (remote_owner_id, (balance::currency));
INSERT INTO wallets
                (remote_id, balance, owner, remote_owner_id)
         SELECT p.mangopay_wallet_id
              , (p.balance, 'EUR')::currency_amount
              , p.id
              , p.mangopay_user_id
           FROM participants p
          WHERE p.mangopay_wallet_id IS NOT NULL;
INSERT INTO wallets
                (remote_id, balance, owner, remote_owner_id, is_current)
         SELECT e.payload->'old_wallet_id'
              , ('0.00', 'EUR')::currency_amount
              , e.participant
              , e.payload->'old_user_id'
              , false
           FROM "events" e
          WHERE e.type = 'mangopay-account-change';
CREATE FUNCTION EUR(numeric) RETURNS currency_amount AS $$
    BEGIN RETURN ($1, 'EUR'); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
DROP VIEW sponsors;
ALTER TABLE participants DROP COLUMN mangopay_wallet_id;
ALTER TABLE participants
        ALTER COLUMN goal DROP DEFAULT,
        ALTER COLUMN goal TYPE currency_amount USING EUR(goal),
        ALTER COLUMN goal SET DEFAULT NULL;
ALTER TABLE participants
        ALTER COLUMN giving DROP DEFAULT,
        ALTER COLUMN giving TYPE currency_amount USING EUR(giving);
ALTER TABLE participants
        ALTER COLUMN receiving DROP DEFAULT,
        ALTER COLUMN receiving TYPE currency_amount USING EUR(receiving);
ALTER TABLE participants
        ALTER COLUMN taking DROP DEFAULT,
        ALTER COLUMN taking TYPE currency_amount USING EUR(taking);
ALTER TABLE participants
        ALTER COLUMN leftover DROP DEFAULT,
        ALTER COLUMN leftover TYPE currency_amount USING EUR(leftover);
ALTER TABLE participants
        ALTER COLUMN balance DROP DEFAULT,
        ALTER COLUMN balance TYPE currency_amount USING EUR(balance);
CREATE FUNCTION initialize_amounts() RETURNS trigger AS $$
        BEGIN
            NEW.giving = COALESCE(NEW.giving, zero(NEW.main_currency));
            NEW.receiving = COALESCE(NEW.receiving, zero(NEW.main_currency));
            NEW.taking = COALESCE(NEW.taking, zero(NEW.main_currency));
            NEW.leftover = COALESCE(NEW.leftover, zero(NEW.main_currency));
            NEW.balance = COALESCE(NEW.balance, zero(NEW.main_currency));
            RETURN NEW;
        END;
    $$ LANGUAGE plpgsql;
CREATE TRIGGER initialize_amounts BEFORE INSERT ON participants
        FOR EACH ROW EXECUTE PROCEDURE initialize_amounts();
CREATE VIEW sponsors AS
        SELECT *
          FROM participants p
         WHERE status = 'active'
           AND kind = 'organization'
           AND giving > receiving
           AND giving >= 10
           AND hide_from_lists = 0
           AND profile_noindex = 0
        ;
DROP VIEW current_takes;
ALTER TABLE takes
        ALTER COLUMN amount DROP DEFAULT,
        ALTER COLUMN amount TYPE currency_amount USING EUR(amount),
        ALTER COLUMN amount SET DEFAULT NULL;
ALTER TABLE takes
        ALTER COLUMN actual_amount DROP DEFAULT,
        ALTER COLUMN actual_amount TYPE currency_amount USING EUR(actual_amount),
        ALTER COLUMN actual_amount SET DEFAULT NULL;
CREATE VIEW current_takes AS
        SELECT * FROM (
             SELECT DISTINCT ON (member, team) t.*
               FROM takes t
           ORDER BY member, team, mtime DESC
        ) AS anon WHERE amount IS NOT NULL;
DROP FUNCTION EUR(numeric);
ALTER TABLE paydays
        ALTER COLUMN transfer_volume DROP DEFAULT,
        ALTER COLUMN transfer_volume TYPE currency_basket USING (transfer_volume, '0.00'),
        ALTER COLUMN transfer_volume SET DEFAULT ('0.00', '0.00');
ALTER TABLE paydays
        ALTER COLUMN take_volume DROP DEFAULT,
        ALTER COLUMN take_volume TYPE currency_basket USING (take_volume, '0.00'),
        ALTER COLUMN take_volume SET DEFAULT ('0.00', '0.00');
ALTER TABLE paydays
        ALTER COLUMN week_deposits DROP DEFAULT,
        ALTER COLUMN week_deposits TYPE currency_basket USING (week_deposits, '0.00'),
        ALTER COLUMN week_deposits SET DEFAULT ('0.00', '0.00');
ALTER TABLE paydays
        ALTER COLUMN week_withdrawals DROP DEFAULT,
        ALTER COLUMN week_withdrawals TYPE currency_basket USING (week_withdrawals, '0.00'),
        ALTER COLUMN week_withdrawals SET DEFAULT ('0.00', '0.00');
ALTER TABLE paydays
        ALTER COLUMN transfer_volume_refunded DROP DEFAULT,
        ALTER COLUMN transfer_volume_refunded TYPE currency_basket USING (transfer_volume_refunded, '0.00'),
        ALTER COLUMN transfer_volume_refunded SET DEFAULT ('0.00', '0.00');
ALTER TABLE paydays
        ALTER COLUMN week_deposits_refunded DROP DEFAULT,
        ALTER COLUMN week_deposits_refunded TYPE currency_basket USING (week_deposits_refunded, '0.00'),
        ALTER COLUMN week_deposits_refunded SET DEFAULT ('0.00', '0.00');
ALTER TABLE paydays
        ALTER COLUMN week_withdrawals_refunded DROP DEFAULT,
        ALTER COLUMN week_withdrawals_refunded TYPE currency_basket USING (week_withdrawals_refunded, '0.00'),
        ALTER COLUMN week_withdrawals_refunded SET DEFAULT ('0.00', '0.00');
CREATE FUNCTION recompute_balance(bigint) RETURNS currency_amount AS $$
    UPDATE participants p
       SET balance = (
               SELECT sum(w.balance, p.main_currency)
                 FROM wallets w
                WHERE w.owner = p.id
           )
     WHERE id = $1
 RETURNING balance;
$$ LANGUAGE SQL STRICT;
DELETE FROM notifications WHERE event = 'low_balance';
ALTER TABLE balances_at ALTER COLUMN balance TYPE currency_basket USING (balance, '0.00');
ALTER TABLE balances_at RENAME COLUMN balance TO balances;
ALTER TABLE exchange_routes ADD COLUMN currency currency;
UPDATE exchange_routes SET currency = 'EUR' WHERE network = 'mango-cc';
ALTER TABLE exchange_routes ADD CONSTRAINT currency_chk CHECK ((currency IS NULL) = (network <> 'mango-cc'));

-- migration #55
CREATE FUNCTION coalesce_currency_amount(currency_amount, currency) RETURNS currency_amount AS $$
    BEGIN RETURN (COALESCE($1.amount, '0.00'::numeric), COALESCE($1.currency, $2)); END;
$$ LANGUAGE plpgsql IMMUTABLE;
CREATE OR REPLACE FUNCTION initialize_amounts() RETURNS trigger AS $$
    BEGIN
        NEW.giving = coalesce_currency_amount(NEW.giving, NEW.main_currency);
        NEW.receiving = coalesce_currency_amount(NEW.receiving, NEW.main_currency);
        NEW.taking = coalesce_currency_amount(NEW.taking, NEW.main_currency);
        NEW.leftover = coalesce_currency_amount(NEW.leftover, NEW.main_currency);
        NEW.balance = coalesce_currency_amount(NEW.balance, NEW.main_currency);
        RETURN NEW;
    END;
$$ LANGUAGE plpgsql;
DROP TRIGGER initialize_amounts ON participants;
CREATE TRIGGER initialize_amounts
    BEFORE INSERT OR UPDATE ON participants
    FOR EACH ROW EXECUTE PROCEDURE initialize_amounts();

-- migration #56
DELETE FROM app_conf WHERE key = 'update_cached_amounts_every';

-- migration #57
CREATE OR REPLACE FUNCTION round(currency_amount) RETURNS currency_amount AS $$
    BEGIN RETURN (round($1.amount, 2), $1.currency); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OR REPLACE FUNCTION convert(currency_amount, currency, boolean) RETURNS currency_amount AS $$
    DECLARE
        rate numeric;
        result currency_amount;
    BEGIN
        IF ($1.currency = $2) THEN RETURN $1; END IF;
        rate := (
            SELECT r.rate
              FROM currency_exchange_rates r
             WHERE r.source_currency = $1.currency
        );
        IF (rate IS NULL) THEN
            RAISE 'missing exchange rate %->%', $1.currency, $2;
        END IF;
        result := ($1.amount / rate, $2);
        RETURN (CASE WHEN $3 THEN round(result) ELSE result END);
    END;
$$ LANGUAGE plpgsql STRICT;
CREATE OR REPLACE FUNCTION convert(currency_amount, currency) RETURNS currency_amount AS $$
    BEGIN RETURN convert($1, $2, true); END;
$$ LANGUAGE plpgsql STRICT;
CREATE OR REPLACE FUNCTION currency_amount_fuzzy_sum_sfunc(
    currency_amount, currency_amount, currency
) RETURNS currency_amount AS $$
    BEGIN RETURN ($1.amount + (convert($2, $3, false)).amount, $3); END;
$$ LANGUAGE plpgsql STRICT;
DROP AGGREGATE sum(currency_amount, currency);
CREATE AGGREGATE sum(currency_amount, currency) (
    sfunc = currency_amount_fuzzy_sum_sfunc,
    finalfunc = round,
    stype = currency_amount,
    initcond = '(0,)'
);
CREATE OR REPLACE FUNCTION currency_amount_fuzzy_avg_sfunc(
    currency_amount_fuzzy_avg_state, currency_amount, currency
) RETURNS currency_amount_fuzzy_avg_state AS $$
    BEGIN
        IF ($2.currency = $3) THEN
            RETURN ($1._sum + $2.amount, $1._count + 1, $3);
        END IF;
        RETURN ($1._sum + (convert($2, $3, false)).amount, $1._count + 1, $3);
    END;
$$ LANGUAGE plpgsql STRICT;
CREATE OR REPLACE FUNCTION currency_amount_fuzzy_avg_ffunc(currency_amount_fuzzy_avg_state)
RETURNS currency_amount AS $$
    BEGIN RETURN round(
        ((CASE WHEN $1._count = 0 THEN 0 ELSE $1._sum / $1._count END), $1.target)::currency_amount
    ); END;
$$ LANGUAGE plpgsql STRICT;

-- migration #58
UPDATE wallets
   SET is_current = true
  FROM participants p
 WHERE p.id = owner
   AND p.mangopay_user_id = remote_owner_id
   AND is_current IS NULL;

-- migration #59
UPDATE participants
   SET email_lang = (
           SELECT l
             FROM ( SELECT regexp_replace(x, '[-;].*', '') AS l
                      FROM regexp_split_to_table(email_lang, ',') x
                  ) x
            WHERE l IN ('ca', 'cs', 'da', 'de', 'el', 'en', 'eo', 'es', 'et', 'fi',
                        'fr', 'fy', 'hu', 'id', 'it', 'ja', 'ko', 'nb', 'nl', 'pl',
                        'pt', 'ru', 'sl', 'sv', 'tr', 'uk', 'zh')
            LIMIT 1
       )
 WHERE length(email_lang) > 0;

-- migration #60
CREATE OR REPLACE FUNCTION convert(currency_amount, currency, boolean) RETURNS currency_amount AS $$
    DECLARE
        rate numeric;
        result currency_amount;
    BEGIN
        IF ($1.currency = $2) THEN RETURN $1; END IF;
        rate := (
            SELECT r.rate
              FROM currency_exchange_rates r
             WHERE r.source_currency = $1.currency
        );
        IF (rate IS NULL) THEN
            RAISE 'missing exchange rate %->%', $1.currency, $2;
        END IF;
        result := ($1.amount * rate, $2);
        RETURN (CASE WHEN $3 THEN round(result) ELSE result END);
    END;
$$ LANGUAGE plpgsql STRICT;

-- migration #61
ALTER TABLE participants ADD COLUMN accepted_currencies text;
UPDATE participants
   SET accepted_currencies = (
           CASE WHEN accept_all_currencies THEN 'EUR,USD' ELSE main_currency::text END
       )
 WHERE status <> 'stub';
DROP VIEW sponsors;
CREATE OR REPLACE VIEW sponsors AS
    SELECT username, giving, avatar_url
      FROM participants p
     WHERE status = 'active'
       AND kind = 'organization'
       AND giving > receiving
       AND giving >= 10
       AND hide_from_lists = 0
       AND profile_noindex = 0
    ;
ALTER TABLE participants DROP COLUMN accept_all_currencies;

-- migration #62
CREATE FUNCTION make_currency_basket(currency_amount) RETURNS currency_basket AS $$
    BEGIN RETURN (CASE
        WHEN $1.currency = 'EUR' THEN ($1.amount, '0.00'::numeric)
                                 ELSE ('0.00'::numeric, $1.amount)
    END); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE CAST (currency_amount as currency_basket) WITH FUNCTION make_currency_basket(currency_amount);
CREATE FUNCTION make_currency_basket_or_null(currency_amount) RETURNS currency_basket AS $$
    BEGIN RETURN (CASE WHEN $1.amount = 0 THEN NULL ELSE make_currency_basket($1) END); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
ALTER TABLE participants
    DROP CONSTRAINT participants_leftover_check,
    ALTER COLUMN leftover DROP NOT NULL,
    ALTER COLUMN leftover TYPE currency_basket USING make_currency_basket_or_null(leftover);
DROP FUNCTION make_currency_basket_or_null(currency_amount);
DROP VIEW current_takes;
ALTER TABLE takes
    ALTER COLUMN actual_amount TYPE currency_basket USING actual_amount::currency_basket;
CREATE VIEW current_takes AS
    SELECT * FROM (
         SELECT DISTINCT ON (member, team) t.*
           FROM takes t
       ORDER BY member, team, mtime DESC
    ) AS anon WHERE amount IS NOT NULL;
CREATE OR REPLACE FUNCTION initialize_amounts() RETURNS trigger AS $$
    BEGIN
        NEW.giving = coalesce_currency_amount(NEW.giving, NEW.main_currency);
        NEW.receiving = coalesce_currency_amount(NEW.receiving, NEW.main_currency);
        NEW.taking = coalesce_currency_amount(NEW.taking, NEW.main_currency);
        NEW.balance = coalesce_currency_amount(NEW.balance, NEW.main_currency);
        RETURN NEW;
    END;
$$ LANGUAGE plpgsql;
CREATE AGGREGATE sum(currency_basket) (
    sfunc = currency_basket_add,
    stype = currency_basket,
    initcond = '(0.00,0.00)'
);
CREATE FUNCTION empty_currency_basket() RETURNS currency_basket AS $$
    BEGIN RETURN ('0.00'::numeric, '0.00'::numeric); END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- migration #63
CREATE TABLE exchange_events
( id             bigserial         PRIMARY KEY
, timestamp      timestamptz       NOT NULL DEFAULT current_timestamp
, exchange       int               NOT NULL REFERENCES exchanges
, status         exchange_status   NOT NULL
, error          text
, wallet_delta   currency_amount
, UNIQUE (exchange, status)
);

-- migration #64
ALTER TABLE elsewhere
    ADD COLUMN info_fetched_at timestamptz NOT NULL DEFAULT '1970-01-01T00:00:00+00'::timestamptz,
    ALTER COLUMN info_fetched_at SET DEFAULT current_timestamp;
INSERT INTO app_conf VALUES
    ('refetch_elsewhere_data_every', '120'::jsonb);
CREATE OR REPLACE FUNCTION check_rate_limit(k text, cap int, period float) RETURNS boolean AS $$
    SELECT coalesce(
        ( SELECT counter - least(compute_leak(cap, period, r.ts), r.counter)
            FROM rate_limiting AS r
           WHERE r.key = k
        ), 0
    ) < cap;
$$ LANGUAGE sql;

-- migration #65
CREATE TABLE user_secrets
( participant   bigint        NOT NULL REFERENCES participants
, id            int           NOT NULL
, secret        text          NOT NULL
, mtime         timestamptz   NOT NULL DEFAULT current_timestamp
, UNIQUE (participant, id)
);
INSERT INTO user_secrets
     SELECT p.id, 0, p.password, p.password_mtime
       FROM participants p
      WHERE p.password IS NOT NULL
ON CONFLICT (participant, id) DO UPDATE
        SET secret = excluded.secret
          , mtime = excluded.mtime;
INSERT INTO user_secrets
     SELECT p.id, 1, p.session_token, p.session_expires - interval '6 hours'
       FROM participants p
      WHERE p.session_token IS NOT NULL
        AND p.session_expires >= (current_timestamp - interval '30 days')
ON CONFLICT (participant, id) DO UPDATE
        SET secret = excluded.secret
          , mtime = excluded.mtime;
ALTER TABLE participants
    DROP COLUMN password,
    DROP COLUMN password_mtime,
    DROP COLUMN session_token,
    DROP COLUMN session_expires;

-- migration #66
ALTER TABLE participants ADD COLUMN public_name text;

-- migration #67
ALTER TABLE elsewhere DROP COLUMN email;
ALTER TABLE elsewhere ADD COLUMN description text;
UPDATE elsewhere
       SET description = extra_info->>'bio'
     WHERE platform IN ('facebook', 'github', 'gitlab')
       AND length(extra_info->>'bio') > 0;
UPDATE elsewhere
       SET description = extra_info->>'aboutMe'
     WHERE platform = 'google'
       AND length(extra_info->>'aboutMe') > 0;
UPDATE elsewhere
       SET description = extra_info->>'note'
     WHERE platform = 'mastodon'
       AND length(extra_info->>'note') > 0;
UPDATE elsewhere
       SET description = extra_info->'osm'->'user'->>'description'
     WHERE platform = 'openstreetmap'
       AND length(extra_info->'osm'->'user'->>'description') > 0;
UPDATE elsewhere
       SET description = extra_info->>'description'
     WHERE platform IN ('twitch', 'twitter')
       AND length(extra_info->>'description') > 0;
UPDATE elsewhere
       SET description = extra_info->'snippet'->>'description'
     WHERE platform = 'youtube'
       AND length(extra_info->'snippet'->>'description') > 0;

-- migration #68
WITH zeroed_tips AS (
         SELECT t.id
           FROM events e
           JOIN current_tips t ON t.tippee = e.participant
                              AND t.mtime = e.ts
                              AND t.amount = 0
          WHERE e.type = 'set_status' AND e.payload = '"closed"'
             OR e.type = 'set_goal' AND e.payload::text LIKE '"-%"'
     )
DELETE FROM tips t WHERE EXISTS (SELECT 1 FROM zeroed_tips z WHERE z.id = t.id);
UPDATE events
   SET recorder = (payload->>'invitee')::int
 WHERE type IN ('invite_accept', 'invite_refuse');

-- migration #69
ALTER TYPE transfer_context ADD VALUE 'swap';
ALTER TABLE transfers ADD COLUMN counterpart int REFERENCES transfers;
ALTER TABLE transfers ADD CONSTRAINT counterpart_chk CHECK ((counterpart IS NULL) = (context <> 'swap') OR (context = 'swap' AND status <> 'succeeded'));

-- migration #70
ALTER TABLE tips ADD COLUMN paid_in_advance currency_amount;
ALTER TABLE tips ADD CONSTRAINT paid_in_advance_currency_chk CHECK (paid_in_advance::currency = amount::currency);
DROP VIEW current_tips;
CREATE VIEW current_tips AS
        SELECT DISTINCT ON (tipper, tippee) *
          FROM tips
      ORDER BY tipper, tippee, mtime DESC;
DROP FUNCTION update_tip();
ALTER TYPE transfer_context ADD VALUE IF NOT EXISTS 'tip-in-advance';
ALTER TYPE transfer_context ADD VALUE IF NOT EXISTS 'take-in-advance';
ALTER TABLE transfers ADD COLUMN unit_amount currency_amount;
ALTER TABLE transfers ADD CONSTRAINT unit_amount_currency_chk CHECK (unit_amount::currency = amount::currency);

-- migration #71
ALTER TABLE transfers ADD COLUMN virtual boolean;

-- migration #72
INSERT INTO app_conf VALUES ('payin_methods', '{"*": false, "bankwire": false, "card": true, "direct-debit": false}'::jsonb);

-- migration #73
INSERT INTO app_conf VALUES
    ('stripe_connect_id', '"ca_DEYxiYHBHZtGj32l9uczcsunbQOcRq8H"'::jsonb),
    ('stripe_secret_key', '"sk_test_QTUa8AqWXyU2feC32glNgDQd"'::jsonb);
ALTER TABLE participants ADD COLUMN has_payment_account boolean;
CREATE TABLE payment_accounts
( participant           bigint          NOT NULL REFERENCES participants
, provider              text            NOT NULL
, country               text            NOT NULL
, id                    text            NOT NULL CHECK (id <> '')
, is_current            boolean         DEFAULT TRUE CHECK (is_current IS NOT FALSE)
, charges_enabled       boolean         NOT NULL
, default_currency      text
, display_name          text
, token                 json
, connection_ts         timestamptz     NOT NULL DEFAULT current_timestamp
, UNIQUE (participant, provider, country, is_current)
, UNIQUE (provider, id, participant)
);
CREATE OR REPLACE FUNCTION update_has_payment_account() RETURNS trigger AS $$
    DECLARE
        rec record;
    BEGIN
        rec := COALESCE(NEW, OLD);
        UPDATE participants
           SET has_payment_account = (
                   SELECT count(*)
                     FROM payment_accounts
                    WHERE participant = rec.participant
                      AND is_current IS TRUE
               ) > 0
         WHERE id = rec.participant;
        RETURN NULL;
    END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER update_has_payment_account
    AFTER INSERT OR UPDATE OR DELETE ON payment_accounts
    FOR EACH ROW EXECUTE PROCEDURE update_has_payment_account();

-- migration #74
ALTER TYPE transfer_context ADD VALUE IF NOT EXISTS 'fee-refund';

-- migration #75
ALTER TYPE payment_net ADD VALUE IF NOT EXISTS 'stripe-card';
INSERT INTO app_conf VALUES
    ('stripe_publishable_key', '"pk_test_rGZY3Q7ba61df50X0h70iHeZ"'::jsonb);
UPDATE app_conf
   SET value = '{"*": true, "mango-ba": false, "mango-bw": false, "mango-cc": false, "stripe-card": true}'::jsonb
 WHERE key = 'payin_methods';
ALTER TABLE payment_accounts ADD COLUMN pk bigserial PRIMARY KEY;
CREATE TYPE payin_status AS ENUM (
    'pre', 'submitting', 'pending', 'succeeded', 'failed'
);
CREATE TABLE payins
( id               bigserial         PRIMARY KEY
, ctime            timestamptz       NOT NULL DEFAULT current_timestamp
, remote_id        text
, payer            bigint            NOT NULL REFERENCES participants
, amount           currency_amount   NOT NULL CHECK (amount > 0)
, status           payin_status      NOT NULL
, error            text
, route            int               NOT NULL REFERENCES exchange_routes
, amount_settled   currency_amount
, fee              currency_amount   CHECK (fee >= 0)
, CONSTRAINT fee_currency_chk CHECK (fee::currency = amount_settled::currency)
, CONSTRAINT success_chk CHECK (NOT (status = 'succeeded' AND (amount_settled IS NULL OR fee IS NULL)))
);
CREATE INDEX payins_payer_idx ON payins (payer);
CREATE TABLE payin_events
( payin          int               NOT NULL REFERENCES payins
, status         payin_status      NOT NULL
, error          text
, timestamp      timestamptz       NOT NULL
, UNIQUE (payin, status)
);
CREATE TYPE payin_transfer_context AS ENUM ('personal-donation', 'team-donation');
CREATE TYPE payin_transfer_status AS ENUM ('pre', 'pending', 'failed', 'succeeded');
CREATE TABLE payin_transfers
( id            serial                   PRIMARY KEY
, ctime         timestamptz              NOT NULL DEFAULT CURRENT_TIMESTAMP
, remote_id     text
, payin         bigint                   NOT NULL REFERENCES payins
, payer         bigint                   NOT NULL REFERENCES participants
, recipient     bigint                   NOT NULL REFERENCES participants
, destination   bigint                   NOT NULL REFERENCES payment_accounts
, context       payin_transfer_context   NOT NULL
, status        payin_transfer_status    NOT NULL
, error         text
, amount        currency_amount          NOT NULL CHECK (amount > 0)
, unit_amount   currency_amount
, n_units       int
, period        donation_period
, team          bigint                   REFERENCES participants
, CONSTRAINT self_chk CHECK (payer <> recipient)
, CONSTRAINT team_chk CHECK ((context = 'team-donation') = (team IS NOT NULL))
, CONSTRAINT unit_chk CHECK ((unit_amount IS NULL) = (n_units IS NULL))
);
CREATE INDEX payin_transfers_payer_idx ON payin_transfers (payer);
CREATE INDEX payin_transfers_recipient_idx ON payin_transfers (recipient);
ALTER TABLE exchange_routes ADD COLUMN country text;
CREATE TYPE route_status AS ENUM ('pending', 'chargeable', 'consumed', 'failed', 'canceled');
ALTER TABLE exchange_routes ADD COLUMN status route_status;
UPDATE exchange_routes
       SET status = 'canceled'
     WHERE error = 'invalidated';
UPDATE exchange_routes
       SET status = 'chargeable'
     WHERE error IS NULL;
ALTER TABLE exchange_routes ALTER COLUMN status SET NOT NULL;
ALTER TABLE exchange_routes DROP COLUMN error;

-- migration #76
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'AUD';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'BGN';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'BRL';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'CAD';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'CHF';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'CNY';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'CZK';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'DKK';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'GBP';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'HKD';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'HRK';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'HUF';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'IDR';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'ILS';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'INR';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'ISK';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'JPY';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'KRW';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'MXN';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'MYR';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'NOK';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'NZD';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'PHP';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'PLN';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'RON';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'RUB';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'SEK';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'SGD';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'THB';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'TRY';
ALTER TYPE currency ADD VALUE IF NOT EXISTS 'ZAR';
CREATE OR REPLACE FUNCTION get_currency_exponent(currency) RETURNS int AS $$
    BEGIN RETURN (CASE
        WHEN $1 IN ('ISK', 'JPY', 'KRW') THEN 0 ELSE 2
    END); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OR REPLACE FUNCTION coalesce_currency_amount(currency_amount, currency) RETURNS currency_amount AS $$
    DECLARE
        c currency := COALESCE($1.currency, $2);
    BEGIN
        RETURN (COALESCE($1.amount, round(0, get_currency_exponent(c))), c);
    END;
$$ LANGUAGE plpgsql IMMUTABLE;
CREATE OR REPLACE FUNCTION round(currency_amount) RETURNS currency_amount AS $$
    BEGIN RETURN (round($1.amount, get_currency_exponent($1.currency)), $1.currency); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OR REPLACE FUNCTION zero(currency) RETURNS currency_amount AS $$
    BEGIN RETURN (round(0, get_currency_exponent($1)), $1); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OR REPLACE FUNCTION zero(currency_amount) RETURNS currency_amount AS $$
    BEGIN RETURN (round(0, get_currency_exponent($1.currency)), $1.currency); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OR REPLACE FUNCTION convert(currency_amount, currency, boolean) RETURNS currency_amount AS $$
    DECLARE
        rate numeric;
        result currency_amount;
    BEGIN
        IF ($1.currency = $2) THEN RETURN $1; END IF;
        IF ($1.currency = 'EUR' OR $2 = 'EUR') THEN
            rate := (
                SELECT r.rate
                  FROM currency_exchange_rates r
                 WHERE r.source_currency = $1.currency
                   AND r.target_currency = $2
            );
        ELSE
            rate := (
                SELECT r.rate
                  FROM currency_exchange_rates r
                 WHERE r.source_currency = $1.currency
                   AND r.target_currency = 'EUR'
            ) * (
                SELECT r.rate
                  FROM currency_exchange_rates r
                 WHERE r.source_currency = 'EUR'
                   AND r.target_currency = $2
            );
        END IF;
        IF (rate IS NULL) THEN
            RAISE 'missing exchange rate %->%', $1.currency, $2;
        END IF;
        result := ($1.amount * rate, $2);
        RETURN (CASE WHEN $3 THEN round(result) ELSE result END);
    END;
$$ LANGUAGE plpgsql STRICT;

-- migration #77
INSERT INTO app_conf VALUES
    ('check_email_domains', 'true'::jsonb);
INSERT INTO app_conf VALUES
    ('paypal_domain', '"sandbox.paypal.com"'::jsonb),
    ('paypal_id', '"ASTH9rn8IosjJcEwNYqV2KeHadB6O8MKVP7fL7kXeSuOml0ei77FRYU5E1thEF-1cT3Wp3Ibo0jXIbul"'::jsonb),
    ('paypal_secret', '"EAStyBaGBZk9MVBGrI_eb4O4iEVFPZcRoIsbKDwv28wxLzroLDKYwCnjZfr_jDoZyDB5epQVrjZraoFY"'::jsonb);
ALTER TABLE payment_accounts ALTER COLUMN charges_enabled DROP NOT NULL;
ALTER TYPE payment_net ADD VALUE IF NOT EXISTS 'paypal';
CREATE TABLE payin_transfer_events
( payin_transfer   int               NOT NULL REFERENCES payin_transfers
, status           payin_status      NOT NULL
, error            text
, timestamp        timestamptz       NOT NULL
, UNIQUE (payin_transfer, status)
);
ALTER TABLE payin_transfers ADD COLUMN fee currency_amount;
ALTER TABLE payins DROP CONSTRAINT success_chk;
ALTER TABLE participants ADD COLUMN payment_providers integer NOT NULL DEFAULT 0;
UPDATE participants SET payment_providers = 1 WHERE has_payment_account;
CREATE TYPE payment_providers AS ENUM ('stripe', 'paypal');
CREATE OR REPLACE FUNCTION update_payment_providers() RETURNS trigger AS $$
    DECLARE
        rec record;
    BEGIN
        rec := (CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
        UPDATE participants
           SET payment_providers = coalesce((
                   SELECT sum(DISTINCT array_position(
                                           enum_range(NULL::payment_providers),
                                           a.provider::payment_providers
                                       ))
                     FROM payment_accounts a
                    WHERE ( a.participant = rec.participant OR
                            a.participant IN (
                                SELECT t.member
                                  FROM current_takes t
                                 WHERE t.team = rec.participant
                            )
                          )
                      AND a.is_current IS TRUE
                      AND a.verified IS TRUE
               ), 0)
         WHERE id = rec.participant
            OR id IN (
                   SELECT t.team FROM current_takes t WHERE t.member = rec.participant
               );
        RETURN NULL;
    END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER update_payment_providers
    AFTER INSERT OR UPDATE OR DELETE ON payment_accounts
    FOR EACH ROW EXECUTE PROCEDURE update_payment_providers();
ALTER TABLE payment_accounts ADD COLUMN verified boolean NOT NULL DEFAULT TRUE;
DROP TRIGGER update_has_payment_account ON payment_accounts;
DROP FUNCTION update_has_payment_account();
ALTER TABLE participants DROP COLUMN has_payment_account;
UPDATE payment_accounts SET id = id;
ALTER TABLE payment_accounts ALTER COLUMN verified DROP DEFAULT;

-- migration #78
CREATE OR REPLACE FUNCTION update_payment_accounts() RETURNS trigger AS $$
    BEGIN
        UPDATE payment_accounts
           SET verified = coalesce(NEW.verified, false)
         WHERE id = NEW.address
           AND participant = NEW.participant;
        RETURN NULL;
    END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER update_payment_accounts
    AFTER INSERT OR UPDATE ON emails
    FOR EACH ROW EXECUTE PROCEDURE update_payment_accounts();
UPDATE payment_accounts AS a
   SET verified = true
 WHERE verified IS NOT true
   AND ( SELECT e.verified
           FROM emails e
          WHERE e.address = a.id
            AND e.participant = a.participant
       ) IS true;

-- migration #79
ALTER TABLE takes ADD COLUMN paid_in_advance currency_amount;
ALTER TABLE takes ADD CONSTRAINT paid_in_advance_currency_chk CHECK (paid_in_advance::currency = amount::currency);
CREATE INDEX takes_team_idx ON takes (team);
DROP VIEW current_takes;
CREATE VIEW current_takes AS
    SELECT *
      FROM ( SELECT DISTINCT ON (team, member) t.*
               FROM takes t
           ORDER BY team, member, mtime DESC
           ) AS x
     WHERE amount IS NOT NULL;
UPDATE takes AS take
   SET paid_in_advance = coalesce_currency_amount((
           SELECT sum(tr.amount, take.amount::currency)
             FROM transfers tr
            WHERE tr.tippee = take.member
              AND tr.team = take.team
              AND tr.context = 'take-in-advance'
              AND tr.status = 'succeeded'
       ), take.amount::currency) + coalesce_currency_amount((
           SELECT sum(pt.amount, take.amount::currency)
             FROM payin_transfers pt
            WHERE pt.recipient = take.member
              AND pt.team = take.team
              AND pt.context = 'team-donation'
              AND pt.status = 'succeeded'
       ), take.amount::currency) - coalesce_currency_amount((
           SELECT sum(tr.amount, take.amount::currency)
             FROM transfers tr
            WHERE tr.tippee = take.member
              AND tr.team = take.team
              AND tr.context = 'take'
              AND tr.status = 'succeeded'
              AND tr.virtual IS TRUE
       ), take.amount::currency)
  FROM current_takes ct
 WHERE take.id = ct.id;

-- migration #80
CREATE TYPE blacklist_reason AS ENUM ('bounce', 'complaint');
CREATE TABLE email_blacklist
( address        text               NOT NULL
, ts             timestamptz        NOT NULL DEFAULT current_timestamp
, reason         blacklist_reason   NOT NULL
, details        text
, ses_data       jsonb
, ignore_after   timestamptz
, report_id      text
);
CREATE INDEX email_blacklist_idx ON email_blacklist (lower(address));
CREATE UNIQUE INDEX email_blacklist_report_key ON email_blacklist (report_id, address)
    WHERE report_id IS NOT NULL;
INSERT INTO app_conf VALUES
    ('fetch_email_bounces_every', '60'::jsonb),
    ('ses_feedback_queue_url', '""'::jsonb);
DROP INDEX queued_emails_idx;
CREATE UNIQUE INDEX queued_emails_idx ON notifications (id ASC)
    WHERE (email AND email_sent IS NULL);

-- migration #81
DROP INDEX email_blacklist_report_key;
CREATE UNIQUE INDEX email_blacklist_report_key ON email_blacklist (report_id, address);

-- migration #82
ALTER TYPE currency_basket ADD ATTRIBUTE amounts jsonb;
CREATE OR REPLACE FUNCTION empty_currency_basket() RETURNS currency_basket AS $$
    BEGIN RETURN (NULL::numeric,NULL::numeric,jsonb_build_object()); END;
$$ LANGUAGE plpgsql;
CREATE FUNCTION coalesce_currency_basket(currency_basket) RETURNS currency_basket AS $$
    BEGIN
        IF (coalesce($1.EUR, 0) > 0 OR coalesce($1.USD, 0) > 0) THEN
            IF ($1.amounts ? 'EUR' OR $1.amounts ? 'USD') THEN
                RAISE 'got an hybrid currency basket: %', $1;
            END IF;
            RETURN _wrap_amounts(
                jsonb_build_object('EUR', $1.EUR::text, 'USD', $1.USD::text)
            );
        ELSIF (jsonb_typeof($1.amounts) = 'object') THEN
            RETURN $1;
        ELSIF ($1.amounts IS NULL OR jsonb_typeof($1.amounts) <> 'null') THEN
            RETURN (NULL::numeric,NULL::numeric,jsonb_build_object());
        ELSE
            RAISE 'unexpected JSON type: %', jsonb_typeof($1.amounts);
        END IF;
    END;
$$ LANGUAGE plpgsql IMMUTABLE;
CREATE OR REPLACE FUNCTION _wrap_amounts(jsonb) RETURNS currency_basket AS $$
    BEGIN
        IF ($1 IS NULL) THEN
            RETURN (NULL::numeric,NULL::numeric,jsonb_build_object());
        ELSE
            RETURN (NULL::numeric,NULL::numeric,$1);
        END IF;
    END;
$$ LANGUAGE plpgsql IMMUTABLE;
CREATE OR REPLACE FUNCTION make_currency_basket(currency_amount) RETURNS currency_basket AS $$
    BEGIN RETURN (NULL::numeric,NULL::numeric,jsonb_build_object($1.currency::text, $1.amount::text)); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OR REPLACE FUNCTION currency_basket_add(currency_basket, currency_amount)
RETURNS currency_basket AS $$
    DECLARE
        r currency_basket;
    BEGIN
        r := coalesce_currency_basket($1);
        IF ($2.amount IS NULL OR $2.amount = 0 OR $2.currency IS NULL) THEN
            RETURN r;
        END IF;
        r.amounts := jsonb_set(
            r.amounts,
            string_to_array($2.currency::text, ' '),
            (coalesce((r.amounts->>$2.currency::text)::numeric, 0) + $2.amount)::text::jsonb
        );
        RETURN r;
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OR REPLACE FUNCTION currency_basket_add(currency_basket, currency_basket)
RETURNS currency_basket AS $$
    DECLARE
        amounts1 jsonb;
        amounts2 jsonb;
        currency text;
    BEGIN
        amounts1 := (coalesce_currency_basket($1)).amounts;
        amounts2 := (coalesce_currency_basket($2)).amounts;
        FOR currency IN SELECT * FROM jsonb_object_keys(amounts2) LOOP
            amounts1 := jsonb_set(
                amounts1,
                string_to_array(currency, ' '),
                ( coalesce((amounts1->>currency)::numeric, 0) +
                  coalesce((amounts2->>currency)::numeric, 0)
                )::text::jsonb
            );
        END LOOP;
        RETURN _wrap_amounts(amounts1);
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OR REPLACE FUNCTION currency_basket_sub(currency_basket, currency_amount)
RETURNS currency_basket AS $$
    BEGIN RETURN currency_basket_add($1, -$2); END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OR REPLACE FUNCTION currency_basket_sub(currency_basket, currency_basket)
RETURNS currency_basket AS $$
    DECLARE
        amounts1 jsonb;
        amounts2 jsonb;
        currency text;
    BEGIN
        amounts1 := (coalesce_currency_basket($1)).amounts;
        amounts2 := (coalesce_currency_basket($2)).amounts;
        FOR currency IN SELECT * FROM jsonb_object_keys(amounts2) LOOP
            amounts1 := jsonb_set(
                amounts1,
                string_to_array(currency, ' '),
                ( coalesce((amounts1->>currency)::numeric, 0) -
                  coalesce((amounts2->>currency)::numeric, 0)
                )::text::jsonb
            );
        END LOOP;
        RETURN _wrap_amounts(amounts1);
    END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OR REPLACE FUNCTION currency_basket_contains(currency_basket, currency_amount)
RETURNS boolean AS $$
    BEGIN RETURN coalesce(coalesce_currency_basket($1)->$2.currency::text, 0) >= $2.amount; END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
DROP AGGREGATE basket_sum(currency_amount);
CREATE AGGREGATE basket_sum(currency_amount) (
    sfunc = currency_basket_add,
    stype = currency_basket,
    initcond = '(,,{})'
);
DROP AGGREGATE sum(currency_basket);
CREATE AGGREGATE sum(currency_basket) (
    sfunc = currency_basket_add,
    stype = currency_basket,
    initcond = '(,,{})'
);
CREATE FUNCTION get_amount_from_currency_basket(currency_basket, currency)
RETURNS numeric AS $$
    BEGIN RETURN (coalesce_currency_basket($1)).amounts->>$2::text; END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE FUNCTION get_amount_from_currency_basket(currency_basket, text)
RETURNS numeric AS $$
    BEGIN RETURN (coalesce_currency_basket($1)).amounts->>$2; END;
$$ LANGUAGE plpgsql IMMUTABLE STRICT;
CREATE OPERATOR -> (
    leftarg = currency_basket,
    rightarg = currency,
    procedure = get_amount_from_currency_basket
);
CREATE OPERATOR -> (
    leftarg = currency_basket,
    rightarg = text,
    procedure = get_amount_from_currency_basket
);
ALTER TABLE paydays ALTER COLUMN transfer_volume           SET DEFAULT empty_currency_basket();
ALTER TABLE paydays ALTER COLUMN take_volume               SET DEFAULT empty_currency_basket();
ALTER TABLE paydays ALTER COLUMN week_deposits             SET DEFAULT empty_currency_basket();
ALTER TABLE paydays ALTER COLUMN week_withdrawals          SET DEFAULT empty_currency_basket();
ALTER TABLE paydays ALTER COLUMN transfer_volume_refunded  SET DEFAULT empty_currency_basket();
ALTER TABLE paydays ALTER COLUMN week_deposits_refunded    SET DEFAULT empty_currency_basket();
ALTER TABLE paydays ALTER COLUMN week_withdrawals_refunded SET DEFAULT empty_currency_basket();
UPDATE participants
   SET accepted_currencies = NULL
 WHERE status = 'stub'
   AND accepted_currencies IS NOT NULL;

-- migration #83
ALTER TABLE emails DROP CONSTRAINT emails_participant_address_key;
CREATE UNIQUE INDEX emails_participant_address_key ON emails (participant, lower(address));

-- migration #84
UPDATE elsewhere
   SET extra_info = (
           extra_info::jsonb - 'events_url' - 'followers_url' - 'following_url'
           - 'gists_url' - 'html_url' - 'organizations_url' - 'received_events_url'
           - 'repos_url' - 'starred_url' - 'subscriptions_url'
       )::json
 WHERE platform = 'github'
   AND json_typeof(extra_info) = 'object';
UPDATE elsewhere
   SET extra_info = (extra_info::jsonb - 'id_str' - 'entities' - 'status')::json
 WHERE platform = 'twitter'
   AND json_typeof(extra_info) = 'object';

-- migration #85
CREATE OR REPLACE FUNCTION update_payment_providers() RETURNS trigger AS $$
    DECLARE
        rec record;
    BEGIN
        rec := (CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END);
        UPDATE participants
           SET payment_providers = coalesce((
                   SELECT sum(DISTINCT array_position(
                                           enum_range(NULL::payment_providers),
                                           a.provider::payment_providers
                                       ))
                     FROM payment_accounts a
                    WHERE ( a.participant = rec.participant OR
                            a.participant IN (
                                SELECT t.member
                                  FROM current_takes t
                                 WHERE t.team = rec.participant
                            )
                          )
                      AND a.is_current IS TRUE
                      AND a.verified IS TRUE
                      AND coalesce(a.charges_enabled, true)
               ), 0)
         WHERE id = rec.participant
            OR id IN (
                   SELECT t.team FROM current_takes t WHERE t.member = rec.participant
               );
        RETURN NULL;
    END;
$$ LANGUAGE plpgsql;
UPDATE participants AS p
   SET payment_providers = coalesce((
           SELECT sum(DISTINCT array_position(
                                   enum_range(NULL::payment_providers),
                                   a.provider::payment_providers
                               ))
             FROM payment_accounts a
            WHERE ( a.participant = p.id OR
                    a.participant IN (
                        SELECT t.member
                          FROM current_takes t
                         WHERE t.team = p.id
                    )
                  )
              AND a.is_current IS TRUE
              AND a.verified IS TRUE
              AND coalesce(a.charges_enabled, true)
       ), 0)
 WHERE EXISTS (
           SELECT a.id
             FROM payment_accounts a
            WHERE a.participant = p.id
              AND a.charges_enabled IS false
       );
