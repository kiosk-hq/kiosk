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
-- Name: cart_mandates; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.cart_mandates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mandate_id text NOT NULL,
    intent_mandate_id uuid NOT NULL,
    user_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    issuer text NOT NULL,
    line_items jsonb NOT NULL,
    total_amount_cents bigint NOT NULL,
    currency text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    raw_jws text NOT NULL
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
-- Name: intent_mandates; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.intent_mandates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    mandate_id text NOT NULL,
    user_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    issuer text NOT NULL,
    scope text NOT NULL,
    cap_amount_cents bigint NOT NULL,
    currency text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    raw_jws text NOT NULL
);


--
-- Name: payment_mandates; Type: TABLE; Schema: kiosk; Owner: -
--

CREATE TABLE kiosk.payment_mandates (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    cart_mandate_id uuid NOT NULL,
    user_id uuid NOT NULL,
    agent_id uuid NOT NULL,
    issuer text NOT NULL,
    psp_reference text NOT NULL,
    settled_amount_cents bigint NOT NULL,
    currency text NOT NULL,
    settled_at timestamp with time zone NOT NULL,
    raw_jws text NOT NULL
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
-- Name: ar_internal_metadata; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ar_internal_metadata (
    key character varying NOT NULL,
    value character varying,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_items (
    id bigint NOT NULL,
    order_id uuid NOT NULL,
    product_id bigint NOT NULL,
    qty integer DEFAULT 1 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: order_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.order_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: order_items_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.order_items_id_seq OWNED BY public.order_items.id;


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    status character varying DEFAULT 'created'::character varying NOT NULL,
    total_cents integer DEFAULT 0 NOT NULL,
    slot_at timestamp with time zone,
    address text,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    sku character varying NOT NULL,
    name character varying NOT NULL,
    price_cents integer NOT NULL,
    stock integer DEFAULT 0 NOT NULL,
    created_at timestamp(6) without time zone NOT NULL,
    updated_at timestamp(6) without time zone NOT NULL
);


--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: products_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.products_id_seq OWNED BY public.products.id;


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
-- Name: order_items id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items ALTER COLUMN id SET DEFAULT nextval('public.order_items_id_seq'::regclass);


--
-- Name: products id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products ALTER COLUMN id SET DEFAULT nextval('public.products_id_seq'::regclass);


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
-- Name: cart_mandates cart_mandates_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.cart_mandates
    ADD CONSTRAINT cart_mandates_pkey PRIMARY KEY (id);


--
-- Name: cart_mandates cart_mandates_user_id_mandate_id_key; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.cart_mandates
    ADD CONSTRAINT cart_mandates_user_id_mandate_id_key UNIQUE (user_id, mandate_id);


--
-- Name: device_authorizations device_authorizations_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.device_authorizations
    ADD CONSTRAINT device_authorizations_pkey PRIMARY KEY (id);


--
-- Name: intent_mandates intent_mandates_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.intent_mandates
    ADD CONSTRAINT intent_mandates_pkey PRIMARY KEY (id);


--
-- Name: intent_mandates intent_mandates_user_id_mandate_id_key; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.intent_mandates
    ADD CONSTRAINT intent_mandates_user_id_mandate_id_key UNIQUE (user_id, mandate_id);


--
-- Name: payment_mandates payment_mandates_cart_mandate_id_key; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.payment_mandates
    ADD CONSTRAINT payment_mandates_cart_mandate_id_key UNIQUE (cart_mandate_id);


--
-- Name: payment_mandates payment_mandates_pkey; Type: CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.payment_mandates
    ADD CONSTRAINT payment_mandates_pkey PRIMARY KEY (id);


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
-- Name: ar_internal_metadata ar_internal_metadata_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ar_internal_metadata
    ADD CONSTRAINT ar_internal_metadata_pkey PRIMARY KEY (key);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


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
-- Name: idx_cart_mandates_intent; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_cart_mandates_intent ON kiosk.cart_mandates USING btree (intent_mandate_id);


--
-- Name: idx_cart_mandates_user_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_cart_mandates_user_id ON kiosk.cart_mandates USING btree (user_id);


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
-- Name: idx_intent_mandates_agent_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_intent_mandates_agent_id ON kiosk.intent_mandates USING btree (agent_id);


--
-- Name: idx_intent_mandates_user_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_intent_mandates_user_id ON kiosk.intent_mandates USING btree (user_id);


--
-- Name: idx_payment_mandates_cart; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_payment_mandates_cart ON kiosk.payment_mandates USING btree (cart_mandate_id);


--
-- Name: idx_payment_mandates_user_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_payment_mandates_user_id ON kiosk.payment_mandates USING btree (user_id);


--
-- Name: idx_reservations_expiry; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_reservations_expiry ON kiosk.reservations USING btree (expires_at) WHERE (released_at IS NULL);


--
-- Name: idx_reservations_user_id; Type: INDEX; Schema: kiosk; Owner: -
--

CREATE INDEX idx_reservations_user_id ON kiosk.reservations USING btree (user_id);


--
-- Name: index_order_items_on_order_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_order_items_on_order_id ON public.order_items USING btree (order_id);


--
-- Name: index_order_items_on_product_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_order_items_on_product_id ON public.order_items USING btree (product_id);


--
-- Name: index_orders_on_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX index_orders_on_user_id ON public.orders USING btree (user_id);


--
-- Name: index_products_on_sku; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX index_products_on_sku ON public.products USING btree (sku);


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
-- Name: cart_mandates cart_mandates_intent_mandate_id_fkey; Type: FK CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.cart_mandates
    ADD CONSTRAINT cart_mandates_intent_mandate_id_fkey FOREIGN KEY (intent_mandate_id) REFERENCES kiosk.intent_mandates(id) ON DELETE CASCADE;


--
-- Name: payment_mandates payment_mandates_cart_mandate_id_fkey; Type: FK CONSTRAINT; Schema: kiosk; Owner: -
--

ALTER TABLE ONLY kiosk.payment_mandates
    ADD CONSTRAINT payment_mandates_cart_mandate_id_fkey FOREIGN KEY (cart_mandate_id) REFERENCES kiosk.cart_mandates(id) ON DELETE CASCADE;


--
-- Name: order_items fk_rails_e3cb28f071; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT fk_rails_e3cb28f071 FOREIGN KEY (order_id) REFERENCES public.orders(id);


--
-- Name: order_items fk_rails_f1a29ddd47; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT fk_rails_f1a29ddd47 FOREIGN KEY (product_id) REFERENCES public.products(id);


--
-- Name: orders fk_rails_f868b47f6a; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_rails_f868b47f6a FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

SET search_path TO "$user", public;

INSERT INTO "schema_migrations" (version) VALUES
('20260618131463'),
('20260618131462'),
('20260618131461'),
('20260618131460'),
('20260618131459'),
('20260618131458'),
('20260618131457'),
('20260101000000');

