# Oryzon Deco — Architecture Technique Complète

> Stack : Next.js 15 · TypeScript · Tailwind CSS · Supabase · Stripe · Cloudinary · Resend · Shadcn/ui

---

## 1. Vue d'ensemble

```
oryzon-deco/
├── app/                        # Next.js App Router
│   ├── (shop)/                 # Layout boutique publique
│   │   ├── page.tsx            # Landing page
│   │   ├── catalogue/          # Catalogue produits
│   │   ├── produit/[slug]/     # Page produit
│   │   ├── panier/             # Panier
│   │   └── commande/           # Tunnel d'achat
│   ├── (auth)/                 # Layout authentification
│   │   ├── connexion/
│   │   └── inscription/
│   ├── compte/                 # Espace client (protégé)
│   │   ├── commandes/
│   │   ├── favoris/
│   │   └── profil/
│   ├── admin/                  # Dashboard admin (protégé)
│   │   ├── dashboard/
│   │   ├── produits/
│   │   ├── commandes/
│   │   ├── clients/
│   │   ├── promotions/
│   │   └── parametres/
│   └── api/                    # API Routes
│       ├── stripe/
│       ├── webhooks/
│       └── revalidate/
├── components/
│   ├── ui/                     # Shadcn/ui + custom
│   ├── shop/                   # Composants boutique
│   ├── admin/                  # Composants dashboard
│   └── shared/                 # Navbar, Footer, etc.
├── lib/
│   ├── supabase/               # Client + types
│   ├── stripe/                 # Config paiement
│   ├── cloudinary/             # Upload médias
│   └── resend/                 # Emails transactionnels
├── hooks/                      # Custom React hooks
├── types/                      # TypeScript types
└── public/                     # Assets statiques
```

---

## 2. Base de données Supabase

### Tables principales

```sql
-- Produits
CREATE TABLE products (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        text UNIQUE NOT NULL,
  name        text NOT NULL,
  description text,
  price       numeric(10,2) NOT NULL,
  old_price   numeric(10,2),
  stock       int DEFAULT 0,
  category_id uuid REFERENCES categories(id),
  images      text[],           -- URLs Cloudinary
  badge       text,             -- 'new' | 'promo' | 'trend'
  is_active   boolean DEFAULT true,
  is_featured boolean DEFAULT false,
  seo_title   text,
  seo_desc    text,
  created_at  timestamptz DEFAULT now()
);

-- Catégories
CREATE TABLE categories (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug      text UNIQUE NOT NULL,
  name      text NOT NULL,
  image_url text,
  order_pos int DEFAULT 0
);

-- Commandes
CREATE TABLE orders (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid REFERENCES auth.users(id),
  guest_email     text,
  status          text DEFAULT 'pending',
  -- pending | confirmed | shipped | delivered | cancelled
  total           numeric(10,2) NOT NULL,
  stripe_id       text,
  shipping_addr   jsonb,
  items           jsonb,        -- snapshot produits
  tracking_number text,
  created_at      timestamptz DEFAULT now()
);

-- Clients
CREATE TABLE profiles (
  id         uuid PRIMARY KEY REFERENCES auth.users(id),
  full_name  text,
  phone      text,
  created_at timestamptz DEFAULT now()
);

-- Favoris
CREATE TABLE wishlists (
  user_id    uuid REFERENCES auth.users(id),
  product_id uuid REFERENCES products(id),
  PRIMARY KEY (user_id, product_id)
);

-- Promotions
CREATE TABLE promotions (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code       text UNIQUE NOT NULL,
  type       text,             -- 'percent' | 'fixed'
  value      numeric(10,2),
  min_order  numeric(10,2),
  expires_at timestamptz,
  uses_left  int
);

-- Avis clients
CREATE TABLE reviews (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid REFERENCES products(id),
  user_id    uuid REFERENCES auth.users(id),
  rating     int CHECK (rating BETWEEN 1 AND 5),
  comment    text,
  is_visible boolean DEFAULT false,
  created_at timestamptz DEFAULT now()
);
```

### Row Level Security (RLS)

```sql
-- Produits visibles par tous, modifiables par admins uniquement
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Public read" ON products FOR SELECT USING (is_active = true);
CREATE POLICY "Admin write" ON products FOR ALL USING (
  auth.jwt() ->> 'role' = 'admin'
);

-- Commandes visibles par le propriétaire ou admin
CREATE POLICY "Owner read" ON orders FOR SELECT USING (
  user_id = auth.uid() OR auth.jwt() ->> 'role' = 'admin'
);
```

---

## 3. Authentification

**Fournisseurs activés dans Supabase Auth :**
- Email + mot de passe
- Google OAuth
- SMS/OTP (via Twilio)

**Middleware Next.js :**
```typescript
// middleware.ts
import { createMiddlewareClient } from '@supabase/auth-helpers-nextjs';

export async function middleware(req: NextRequest) {
  const res = NextResponse.next();
  const supabase = createMiddlewareClient({ req, res });
  const { data: { session } } = await supabase.auth.getSession();

  // Protéger /compte et /admin
  if (req.nextUrl.pathname.startsWith('/compte') && !session) {
    return NextResponse.redirect(new URL('/connexion', req.url));
  }
  if (req.nextUrl.pathname.startsWith('/admin')) {
    if (!session || session.user.user_metadata?.role !== 'admin') {
      return NextResponse.redirect(new URL('/', req.url));
    }
  }
  return res;
}
```

**Important :** Le catalogue est accessible sans compte. L'inscription n'est requise que pour suivre ses commandes, favoris et historique.

---

## 4. Tunnel d'achat (Stripe)

```
Client → /panier → /commande/livraison → /commande/paiement (Stripe) → /commande/confirmation
                                                    ↓
                                          Stripe Checkout Session
                                                    ↓
                                          Webhook → mise à jour order
                                                    ↓
                                          Email confirmation (Resend)
```

**Création session Stripe :**
```typescript
// app/api/stripe/checkout/route.ts
const session = await stripe.checkout.sessions.create({
  mode: 'payment',
  payment_method_types: ['card'],
  line_items: cart.items.map(item => ({
    price_data: {
      currency: 'eur',
      product_data: { name: item.name, images: [item.image] },
      unit_amount: Math.round(item.price * 100),
    },
    quantity: item.qty,
  })),
  success_url: `${origin}/commande/confirmation?session_id={CHECKOUT_SESSION_ID}`,
  cancel_url: `${origin}/panier`,
  customer_email: email,
  metadata: { order_id: orderId },
});
```

**Paiement en plusieurs fois :** Stripe propose Klarna / Alma nativement — à activer dans le Dashboard Stripe.

---

## 5. Gestion des médias (Cloudinary)

```typescript
// lib/cloudinary/upload.ts
export async function uploadProductImage(file: File) {
  const formData = new FormData();
  formData.append('file', file);
  formData.append('upload_preset', 'oryzon_products');
  formData.append('folder', 'oryzon-deco/products');

  const res = await fetch(
    `https://api.cloudinary.com/v1_1/${CLOUD_NAME}/image/upload`,
    { method: 'POST', body: formData }
  );
  const data = await res.json();
  return data.secure_url;
}
```

**Transformations auto :**
- Thumbnail produit : `w_600,h_800,c_fill,q_auto,f_webp`
- Hero banner : `w_1920,h_1080,c_fill,q_auto,f_webp`
- Mobile optimisé : `w_400,q_auto,f_webp`

---

## 6. Emails transactionnels (Resend)

| Déclencheur | Template |
|---|---|
| Nouvelle commande | Confirmation avec récap + numéro de suivi |
| Expédition | Email avec lien de tracking |
| Inscription | Email de bienvenue + code promo |
| Panier abandonné | Relance J+1 avec rappel produits |
| Avis client | Demande d'avis J+7 après livraison |

```typescript
// lib/resend/emails.ts
await resend.emails.send({
  from: 'Oryzon Deco <bonjour@oryzondeco.fr>',
  to: customer.email,
  subject: `Votre commande #${order.id.slice(0,8)} est confirmée`,
  react: OrderConfirmationEmail({ order, customer }),
});
```

---

## 7. Dashboard Admin

### Accès : `/admin` — réservé au rôle `admin`

### Fonctionnalités par module

**Catalogue**
- Ajouter / modifier / archiver un produit
- Upload photos (drag & drop, multi-images, recadrage)
- Gestion des stocks en temps réel
- Activation/désactivation badge (Nouveau, Promo, Tendance)
- Tri et réorganisation des produits

**Commandes**
- Liste avec filtres (statut, date, montant)
- Détail commande (produits, client, adresse, paiement)
- Changement de statut (confirmer, expédier, livrer, annuler)
- Ajout numéro de suivi
- Export CSV

**Clients**
- Liste clients inscrits + commandes invités
- Fiche client (historique, total dépensé, favoris)
- Blacklist / suspension

**Promotions**
- Créer codes promo (% ou montant fixe)
- Définir conditions (montant min, expiration, nb utilisations)
- Statistiques d'utilisation

**Homepage**
- Modifier slogan hero
- Activer/désactiver sections
- Choisir les best sellers mis en avant
- Modifier textes CTA

**Analytics**
- CA du jour / semaine / mois
- Commandes en attente
- Produits les plus vendus
- Taux de conversion (visites vs commandes)
- Top clients

**SEO**
- Méta title & description par page/produit
- URL canonique
- Schema.org Product automatique

---

## 8. Espace Client

### Accès : `/compte` — connexion requise

**Pages :**
- `/compte` — Tableau de bord (dernières commandes, favoris récents)
- `/compte/commandes` — Historique complet avec statuts
- `/compte/commandes/[id]` — Détail + suivi livraison
- `/compte/favoris` — Wishlist sauvegardée
- `/compte/profil` — Modifier nom, email, téléphone, mot de passe

---

## 9. Performance & SEO

```typescript
// next.config.ts
const nextConfig = {
  images: {
    domains: ['res.cloudinary.com'],
    formats: ['image/webp', 'image/avif'],
  },
  experimental: {
    optimisticClientCache: true,
  },
};
```

**Bonnes pratiques appliquées :**
- Images WebP/AVIF via `next/image`
- Server Components par défaut (pas de JS inutile côté client)
- Streaming SSR pour le catalogue (Suspense boundaries)
- ISR (revalidation toutes les 60s) pour les pages produit
- Schema.org `Product` sur chaque fiche produit
- Sitemap XML auto-généré
- `robots.txt` configuré

---

## 10. Variables d'environnement

```env
# Supabase
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=

# Stripe
NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=
STRIPE_SECRET_KEY=
STRIPE_WEBHOOK_SECRET=

# Cloudinary
NEXT_PUBLIC_CLOUDINARY_CLOUD_NAME=
CLOUDINARY_API_KEY=
CLOUDINARY_API_SECRET=

# Resend
RESEND_API_KEY=

# App
NEXT_PUBLIC_SITE_URL=https://oryzondeco.fr
ADMIN_WHATSAPP=+33600000000
```

---

## 11. Déploiement (Vercel)

```
main branch → Production (oryzondeco.fr)
develop branch → Preview (preview.oryzondeco.fr)
```

**Checklist mise en ligne :**
- [ ] Configurer domaine custom sur Vercel
- [ ] Activer Edge Functions pour le middleware auth
- [ ] Configurer webhook Stripe (URL de prod)
- [ ] Activer Supabase RLS sur toutes les tables
- [ ] Tester tunnel d'achat complet
- [ ] Vérifier emails Resend (DNS SPF/DKIM)
- [ ] Google Search Console + Analytics

---

## 12. Roadmap recommandée

| Phase | Durée | Contenu |
|---|---|---|
| **Phase 1** | 2 semaines | Landing page + catalogue + fiche produit |
| **Phase 2** | 1 semaine | Panier + Stripe + confirmation commande |
| **Phase 3** | 1 semaine | Espace client + Dashboard admin basique |
| **Phase 4** | 1 semaine | Admin avancé (analytics, SEO, promos) |
| **Phase 5** | ongoing | Optimisations CRO, A/B tests, fidélisation |
