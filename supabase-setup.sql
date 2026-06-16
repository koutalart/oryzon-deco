-- ═══════════════════════════════════════════════════════════
--  ORyZOn.deco — Script d'initialisation Supabase
--  Coller dans : Supabase Dashboard → SQL Editor → Run
-- ═══════════════════════════════════════════════════════════

-- ─────────────────────────────────────────
--  EXTENSIONS
-- ─────────────────────────────────────────
create extension if not exists "uuid-ossp";

-- ─────────────────────────────────────────
--  PROFILES (clients)
-- ─────────────────────────────────────────
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  email       text,
  phone       text,
  address     text,
  city        text,
  is_admin    boolean default false,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now()
);

-- Auto-créer un profil à chaque inscription
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, full_name)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1))
  );
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ─────────────────────────────────────────
--  CATEGORIES
-- ─────────────────────────────────────────
create table if not exists public.categories (
  id          serial primary key,
  name        text not null unique,
  slug        text not null unique,
  description text,
  sort_order  integer default 0,
  created_at  timestamptz default now()
);

insert into public.categories (name, slug, sort_order) values
  ('Salon',           'salon',           1),
  ('Chambre',         'chambre',         2),
  ('Salle à manger',  'salle-a-manger',  3),
  ('Décoration',      'decoration',      4),
  ('Salle de bain',   'salle-de-bain',   5),
  ('Extérieur',       'exterieur',       6)
on conflict (slug) do nothing;

-- ─────────────────────────────────────────
--  PRODUCTS
-- ─────────────────────────────────────────
create table if not exists public.products (
  id              serial primary key,
  name            text not null,
  slug            text unique,
  description     text,
  price           integer not null default 0,  -- en Ariary
  compare_price   integer,                      -- prix barré
  category_id     integer references public.categories(id),
  stock_qty       integer not null default 0,
  sku             text unique,
  images          text[],                       -- URLs Cloudinary
  is_active       boolean default true,
  is_featured     boolean default false,
  weight_kg       decimal(5,2),
  dimensions      jsonb,                        -- {l, w, h}
  materials       text[],
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

-- Quelques produits de démo
insert into public.products (name, slug, price, compare_price, category_id, stock_qty, is_featured, materials) values
  ('Canapé Lin Naturel 3 places',     'canape-lin-3p',          189000, 220000, 1, 3,  true,  array['Lin','Bois de chêne']),
  ('Table basse en teck massif',       'table-basse-teck',        87500,  null,  1, 7,  true,  array['Teck massif']),
  ('Lampe Wabi-Sabi bambou',           'lampe-wabi-bambou',       24900,  null,  4, 0,  false, array['Bambou','Coton']),
  ('Lit plateforme chêne 160×200',     'lit-chene-160',          225000, 260000, 2, 2,  true,  array['Chêne massif']),
  ('Chevet céramique artisanal',        'chevet-ceramique',        34500,  null,  2, 12, false, array['Céramique','Rotin']),
  ('Table à manger acacia 8 couverts', 'table-manger-acacia',    315000,  null,  3, 1,  true,  array['Acacia massif']),
  ('Chaises rotin tressé (lot de 4)',   'chaises-rotin-x4',        96000,  null,  3, 5,  false, array['Rotin','Fer forgé']),
  ('Miroir en rotin oval',              'miroir-rotin-oval',       18900,  null,  4, 9,  false, array['Rotin']),
  ('Coussin kapok bio 45×45',           'coussin-kapok-45',         6900,  null,  4, 24, false, array['Kapok','Coton bio']),
  ('Fauteuil bain de soleil teck',      'fauteuil-soleil-teck',    78000,  null,  6, 4,  false, array['Teck']),
  ('Pot en terre cuite XL',             'pot-terre-cuite-xl',      12500,  null,  6, 0,  false, array['Terre cuite']),
  ('Tapis berbère 200×300',             'tapis-berbere-200',       145000,  null, 1, 3,  true,  array['Laine']),
  ('Étagère murale bois flotté',        'etagere-bois-flotte',     42000,  null,  4, 6,  false, array['Bois flotté']),
  ('Ensemble salle de bain bambou',     'ensemble-sdb-bambou',     56000,  null,  5, 8,  false, array['Bambou']),
  ('Paravent 4 panneaux rotin',         'paravent-rotin-4p',       67500,  null,  1, 2,  false, array['Rotin','Coton'])
on conflict (slug) do nothing;

-- ─────────────────────────────────────────
--  ORDERS
-- ─────────────────────────────────────────
create table if not exists public.orders (
  id              serial primary key,
  user_id         uuid references public.profiles(id),
  -- info client (pour commandes sans compte)
  guest_name      text,
  guest_email     text,
  guest_phone     text,
  -- livraison
  shipping_address text,
  shipping_city    text,
  -- montants
  subtotal        integer not null default 0,
  shipping_fee    integer not null default 0,
  discount        integer not null default 0,
  total_amount    integer not null default 0,
  -- statut
  status          text not null default 'pending'
                  check (status in ('pending','confirmed','shipped','delivered','cancelled')),
  payment_status  text not null default 'unpaid'
                  check (payment_status in ('unpaid','paid','refunded')),
  payment_method  text default 'whatsapp',
  -- notes
  notes           text,
  promo_code      text,
  created_at      timestamptz default now(),
  updated_at      timestamptz default now()
);

-- ─────────────────────────────────────────
--  ORDER ITEMS
-- ─────────────────────────────────────────
create table if not exists public.order_items (
  id          serial primary key,
  order_id    integer not null references public.orders(id) on delete cascade,
  product_id  integer references public.products(id),
  product_name text not null,  -- snapshot au moment de la commande
  qty         integer not null default 1,
  price       integer not null default 0,  -- prix unitaire snapshot
  created_at  timestamptz default now()
);

-- ─────────────────────────────────────────
--  WISHLISTS
-- ─────────────────────────────────────────
create table if not exists public.wishlists (
  id          serial primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  product_id  integer not null references public.products(id) on delete cascade,
  created_at  timestamptz default now(),
  unique(user_id, product_id)
);

-- ─────────────────────────────────────────
--  REVIEWS
-- ─────────────────────────────────────────
create table if not exists public.reviews (
  id          serial primary key,
  product_id  integer not null references public.products(id) on delete cascade,
  user_id     uuid references public.profiles(id),
  rating      integer not null check (rating between 1 and 5),
  comment     text,
  is_approved boolean default false,
  created_at  timestamptz default now()
);

-- ─────────────────────────────────────────
--  PROMOTIONS
-- ─────────────────────────────────────────
create table if not exists public.promotions (
  id              serial primary key,
  code            text not null unique,
  type            text not null check (type in ('percent','fixed')),
  value           integer not null,
  min_order       integer default 0,
  max_uses        integer,
  current_uses    integer default 0,
  expires_at      timestamptz,
  is_active       boolean default true,
  created_at      timestamptz default now()
);

-- ─────────────────────────────────────────
--  CONTACT MESSAGES
-- ─────────────────────────────────────────
create table if not exists public.contact_messages (
  id          serial primary key,
  name        text not null,
  email       text not null,
  phone       text,
  subject     text,
  message     text not null,
  is_read     boolean default false,
  created_at  timestamptz default now()
);

-- ─────────────────────────────────────────
--  ROW LEVEL SECURITY
-- ─────────────────────────────────────────

-- Activer RLS sur toutes les tables
alter table public.profiles          enable row level security;
alter table public.categories        enable row level security;
alter table public.products          enable row level security;
alter table public.orders            enable row level security;
alter table public.order_items       enable row level security;
alter table public.wishlists         enable row level security;
alter table public.reviews           enable row level security;
alter table public.promotions        enable row level security;
alter table public.contact_messages  enable row level security;

-- CATEGORIES & PRODUCTS : lecture publique
create policy "categories_public_read"  on public.categories  for select using (true);
create policy "products_public_read"    on public.products    for select using (is_active = true);

-- PROFILES : chaque user voit le sien + admins voient tout
create policy "profiles_own"   on public.profiles for select using (auth.uid() = id);
create policy "profiles_admin" on public.profiles for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

-- ORDERS : user voit ses commandes + admins voient tout
create policy "orders_own"   on public.orders for select using (user_id = auth.uid());
create policy "orders_admin" on public.orders for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

-- ORDER ITEMS : idem
create policy "order_items_own" on public.order_items for select
  using (exists (select 1 from public.orders o where o.id = order_id and o.user_id = auth.uid()));
create policy "order_items_admin" on public.order_items for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

-- WISHLISTS : user voit les siennes
create policy "wishlists_own" on public.wishlists for all using (user_id = auth.uid());

-- REVIEWS : lecture publique des approuvées, écriture auth
create policy "reviews_public_read"  on public.reviews for select using (is_approved = true);
create policy "reviews_write"        on public.reviews for insert with check (auth.uid() is not null);

-- PROMOTIONS : admins seulement
create policy "promotions_admin" on public.promotions for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

-- CONTACT MESSAGES : insert public, lecture admin
create policy "contact_insert" on public.contact_messages for insert with check (true);
create policy "contact_admin"  on public.contact_messages for select
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

-- ADMIN : accès complet aux produits et catégories
create policy "products_admin" on public.products for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));
create policy "categories_admin" on public.categories for all
  using (exists (select 1 from public.profiles p where p.id = auth.uid() and p.is_admin = true));

-- ─────────────────────────────────────────
--  DONNÉES DE DÉMO (commandes + clients)
-- ─────────────────────────────────────────
-- Pour tester le dashboard sans vrai trafic,
-- décommenter les lignes ci-dessous après avoir
-- créé un compte admin via Authentication → Users

-- insert into public.orders (guest_name, guest_email, guest_phone, total_amount, status, created_at) values
--   ('Aminata Saïd',  'aminata@gmail.com',  '+262 639 11 22 33', 189000, 'delivered', now() - interval '2 days'),
--   ('Moussa Ali',    'moussa@gmail.com',    '+262 639 44 55 66', 87500,  'shipped',   now() - interval '5 days'),
--   ('Faouzia Omar',  'faouzia@gmail.com',   '+262 639 77 88 99', 315000, 'confirmed', now() - interval '1 day'),
--   ('Nasra Hamid',   'nasra@gmail.com',     '+262 639 00 11 22', 24900,  'pending',   now());

-- ═══════════════════════════════════════════════════════════
--  FIN DU SCRIPT
--  Tables créées : profiles, categories, products, orders,
--                  order_items, wishlists, reviews,
--                  promotions, contact_messages
-- ═══════════════════════════════════════════════════════════
