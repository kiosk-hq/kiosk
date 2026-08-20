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
    allowed_roles text[] DEFAULT '{}'::text[] NOT NULL,
    public_key text,
    notification_pubkey text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    spending_cap_cents bigint,
    human_label text
);


--
-- Name: device_authorizations; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.device_authorizations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    device_code_hash text NOT NULL,
    user_code_hash text NOT NULL,
    public_key_pem text,
    kind text DEFAULT 'claim'::text NOT NULL,
    client_id text NOT NULL,
    requested_role text,
    status text NOT NULL,
    user_id uuid,
    expires_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT device_authorizations_kind_check CHECK ((kind = ANY (ARRAY['claim'::text, 'link'::text]))),
    CONSTRAINT device_authorizations_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'approved'::text, 'denied'::text, 'consumed'::text, 'expired'::text])))
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
-- Name: invites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invites (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    list_id uuid NOT NULL,
    code_digest character varying NOT NULL,
    created_by_account_id uuid NOT NULL,
    expires_at timestamp(6) without time zone NOT NULL,
    redeemed_by_account_id uuid,
    redeemed_at timestamp(6) without time zone,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: lists; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.lists (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    account_id uuid NOT NULL,
    title character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: memberships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.memberships (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    list_id uuid NOT NULL,
    account_id uuid NOT NULL,
    role character varying DEFAULT 'member'::character varying NOT NULL,
    created_at timestamp(6) without time zone NOT NULL
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying NOT NULL
);


--
-- Name: todos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.todos (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    list_id uuid NOT NULL,
    title character varying NOT NULL,
    done boolean DEFAULT false NOT NULL,
    created_by_agent_id character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL,
    email character varying,
    encrypted_password character varying DEFAULT ''::character varying NOT NULL
);


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
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: invites invites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT invites_pkey PRIMARY KEY (id);


--
-- Name: lists lists_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lists
    ADD CONSTRAINT lists_pkey PRIMARY KEY (id);


--
-- Name: memberships memberships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT memberships_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: todos todos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.todos
    ADD CONSTRAINT todos_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_agent_tokens_agent_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_agent_tokens_agent_id ON kiosk.agent_tokens USING btree (agent_id);


--
-- Name: idx_agent_tokens_hash; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE UNIQUE INDEX idx_agent_tokens_hash ON kiosk.agent_tokens USING btree (token_hash);


--
-- Name: idx_agents_public_key_live; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE UNIQUE INDEX idx_agents_public_key_live ON kiosk.agents USING btree (public_key) WHERE (revoked_at IS NULL);


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

CREATE UNIQUE INDEX idx_device_authorizations_user_code_pending ON kiosk.device_authorizations USING btree (user_code_hash) WHERE (status = 'pending'::text);


--
-- Name: index_invites_on_code_digest; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_invites_on_code_digest ON public.invites USING btree (code_digest);


--
-- Name: index_invites_on_list_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_invites_on_list_id ON public.invites USING btree (list_id);


--
-- Name: index_lists_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_lists_on_account_id ON public.lists USING btree (account_id);


--
-- Name: index_memberships_on_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memberships_on_account_id ON public.memberships USING btree (account_id);


--
-- Name: index_memberships_on_list_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_memberships_on_list_id ON public.memberships USING btree (list_id);


--
-- Name: index_memberships_on_list_id_and_account_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_memberships_on_list_id_and_account_id ON public.memberships USING btree (list_id, account_id);


--
-- Name: index_todos_on_list; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_todos_on_list ON public.todos USING btree (list_id);


--
-- Name: index_todos_on_list_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_todos_on_list_id ON public.todos USING btree (list_id);


--
-- Name: index_users_on_email; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_users_on_email ON public.users USING btree (email);


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
-- Name: memberships fk_rails_01e79dfbcc; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_01e79dfbcc FOREIGN KEY (list_id) REFERENCES public.lists(id);


--
-- Name: invites fk_rails_1803d89414; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invites
    ADD CONSTRAINT fk_rails_1803d89414 FOREIGN KEY (list_id) REFERENCES public.lists(id);


--
-- Name: todos fk_rails_18fb02510b; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.todos
    ADD CONSTRAINT fk_rails_18fb02510b FOREIGN KEY (list_id) REFERENCES public.lists(id);


--
-- Name: lists fk_rails_3853b78dac; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.lists
    ADD CONSTRAINT fk_rails_3853b78dac FOREIGN KEY (account_id) REFERENCES public.users(id);


--
-- Name: memberships fk_rails_edbc202c67; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.memberships
    ADD CONSTRAINT fk_rails_edbc202c67 FOREIGN KEY (account_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260719000001'),
('20260718000002'),
('20260718000001'),
('20260717000001'),
('20260618131461'),
('20260618131458'),
('20260618131457'),
('20260101000000');

