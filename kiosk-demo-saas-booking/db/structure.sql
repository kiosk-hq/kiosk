SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: kiosk; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA kiosk;


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: current_actor(); Type: FUNCTION; Schema: kiosk; Owner: -
--

CREATE FUNCTION kiosk.current_actor() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(current_setting('app.current_actor', true), '')
$$;


--
-- Name: current_agent_id(); Type: FUNCTION; Schema: kiosk; Owner: -
--

CREATE FUNCTION kiosk.current_agent_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(current_setting('app.current_agent_id', true), '')::uuid
$$;


--
-- Name: current_role(); Type: FUNCTION; Schema: kiosk; Owner: -
--

CREATE FUNCTION kiosk."current_role"() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(current_setting('app.current_role', true), '')
$$;


--
-- Name: current_user_id(); Type: FUNCTION; Schema: kiosk; Owner: -
--

CREATE FUNCTION kiosk.current_user_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(current_setting('app.current_user_id', true), '')::uuid
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: action_log; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.action_log (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    action_name text NOT NULL,
    user_id uuid NOT NULL,
    agent_id uuid,
    role text NOT NULL,
    actor text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    result_status text NOT NULL,
    error_class text,
    error_message text,
    invoked_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: actions; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.actions (
    name text NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: agent_mappings; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.agent_mappings (
    provider text NOT NULL,
    external_id text NOT NULL,
    agent_id uuid NOT NULL
);


--
-- Name: agent_tokens; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.agent_tokens (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    agent_id uuid NOT NULL,
    token_hash text NOT NULL,
    issued_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone
);


--
-- Name: agents; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.agents (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    name text NOT NULL,
    allowed_roles text[] DEFAULT '{}'::text[] NOT NULL,
    public_key text,
    notification_pubkey text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone
);


--
-- Name: device_authorizations; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.device_authorizations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    device_code_hash bytea NOT NULL,
    user_code text NOT NULL,
    client_id text NOT NULL,
    requested_role text,
    status text NOT NULL,
    user_id uuid,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT device_authorizations_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text, 'consumed'::text, 'expired'::text])))
);


--
-- Name: reservations; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.reservations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    agent_id uuid,
    resource_kind text NOT NULL,
    resource_id text NOT NULL,
    args jsonb DEFAULT '{}'::jsonb NOT NULL,
    reserved_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    released_at timestamp with time zone
);


--
-- Name: appointments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    salon_id bigint NOT NULL,
    slot timestamp without time zone NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: salons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.salons (
    id bigint NOT NULL,
    name character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: salons_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.salons_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: salons_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.salons_id_seq OWNED BY public.salons.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: salons id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salons ALTER COLUMN id SET DEFAULT nextval('public.salons_id_seq'::regclass);


--
-- Name: action_log action_log_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.action_log
    ADD CONSTRAINT action_log_pkey PRIMARY KEY (id);


--
-- Name: actions actions_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.actions
    ADD CONSTRAINT actions_pkey PRIMARY KEY (name);


--
-- Name: agent_mappings agent_mappings_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.agent_mappings
    ADD CONSTRAINT agent_mappings_pkey PRIMARY KEY (provider, external_id);


--
-- Name: agent_tokens agent_tokens_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.agent_tokens
    ADD CONSTRAINT agent_tokens_pkey PRIMARY KEY (id);


--
-- Name: agents agents_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.agents
    ADD CONSTRAINT agents_pkey PRIMARY KEY (id);


--
-- Name: device_authorizations device_authorizations_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.device_authorizations
    ADD CONSTRAINT device_authorizations_pkey PRIMARY KEY (id);


--
-- Name: reservations reservations_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.reservations
    ADD CONSTRAINT reservations_pkey PRIMARY KEY (id);


--
-- Name: reservations reservations_unique_active; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.reservations
    ADD CONSTRAINT reservations_unique_active UNIQUE (resource_kind, resource_id, released_at) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: appointments appointments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_pkey PRIMARY KEY (id);


--
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: salons salons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.salons
    ADD CONSTRAINT salons_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_action_log_agent_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_action_log_agent_id ON kiosk.action_log USING btree (agent_id, invoked_at DESC) WHERE (agent_id IS NOT NULL);


--
-- Name: idx_action_log_user_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_action_log_user_id ON kiosk.action_log USING btree (user_id, invoked_at DESC);


--
-- Name: idx_agent_tokens_agent_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_agent_tokens_agent_id ON kiosk.agent_tokens USING btree (agent_id);


--
-- Name: idx_agent_tokens_hash; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE UNIQUE INDEX idx_agent_tokens_hash ON kiosk.agent_tokens USING btree (token_hash);


--
-- Name: idx_agents_user_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_agents_user_id ON kiosk.agents USING btree (user_id) WHERE (revoked_at IS NULL);


--
-- Name: idx_device_authorizations_code_hash; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE UNIQUE INDEX idx_device_authorizations_code_hash ON kiosk.device_authorizations USING btree (device_code_hash);


--
-- Name: idx_device_authorizations_expiry; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_device_authorizations_expiry ON kiosk.device_authorizations USING btree (expires_at) WHERE (status = ANY (ARRAY['pending'::text, 'approved'::text]));


--
-- Name: idx_device_authorizations_user_code_pending; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE UNIQUE INDEX idx_device_authorizations_user_code_pending ON kiosk.device_authorizations USING btree (user_code) WHERE (status = 'pending'::text);


--
-- Name: idx_reservations_expiry; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_reservations_expiry ON kiosk.reservations USING btree (expires_at) WHERE (released_at IS NULL);


--
-- Name: idx_reservations_user_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_reservations_user_id ON kiosk.reservations USING btree (user_id);


--
-- Name: index_appointments_on_salon_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_appointments_on_salon_id ON public.appointments USING btree (salon_id);


--
-- Name: index_appointments_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_appointments_on_user_id ON public.appointments USING btree (user_id);


--
-- Name: action_log action_log_action_name_fkey; Type: FK CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.action_log
    ADD CONSTRAINT action_log_action_name_fkey FOREIGN KEY (action_name) REFERENCES kiosk.actions(name);


--
-- Name: agent_mappings agent_mappings_agent_id_fkey; Type: FK CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.agent_mappings
    ADD CONSTRAINT agent_mappings_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES kiosk.agents(id) ON DELETE CASCADE;


--
-- Name: agent_tokens agent_tokens_agent_id_fkey; Type: FK CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.agent_tokens
    ADD CONSTRAINT agent_tokens_agent_id_fkey FOREIGN KEY (agent_id) REFERENCES kiosk.agents(id) ON DELETE CASCADE;


--
-- Name: agents agents_user_id_fkey; Type: FK CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.agents
    ADD CONSTRAINT agents_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: appointments fk_rails_9e31213785; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT fk_rails_9e31213785 FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: appointments fk_rails_f298f85235; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT fk_rails_f298f85235 FOREIGN KEY (salon_id) REFERENCES public.salons(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260618131462'),
('20260618131461'),
('20260618131460'),
('20260618131459'),
('20260618131458'),
('20260618131457'),
('20260101000000');

