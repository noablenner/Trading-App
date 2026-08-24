# Guide de mise en route — Essai 14 jours, Paywall & Paiement Stripe (mode TEST)

Ce lot ajoute à Edgio : l'inscription avec **prénom + nom**, un **essai gratuit de
14 jours**, un **paywall** à l'expiration, et le **paiement Stripe** (4,99 €/mois).
Tout est en **mode test** pour l'instant.

Le code est prêt. Il reste **3 choses à faire côté serveur** (elles ne se font pas
depuis GitHub) : appliquer la base de données, déployer les fonctions, brancher le
webhook Stripe. Voici exactement où cliquer.

> Rappel important : la **clé secrète Stripe** ne doit JAMAIS être mise dans le code
> ni sur GitHub. On la met uniquement dans les « secrets » de Supabase (étape 2).

---

## Étape 1 — Base de données (2 min)

1. Va sur **Supabase → ton projet → SQL Editor → New query**.
2. Ouvre le fichier **`supabase_billing.sql`** de ce dépôt, copie tout son contenu,
   colle-le dans l'éditeur, puis clique **Run**.
3. C'est tout. Ce script est sans risque et peut être relancé plusieurs fois.

Ce qu'il fait : crée la table `profiles` (prénom, nom, date de fin d'essai, statut
d'abonnement), démarre un essai de 14 jours à chaque inscription, et **bloque l'accès
aux données côté serveur** quand l'essai est fini et qu'il n'y a pas d'abonnement
(sécurité RLS — impossible à contourner en trichant dans le navigateur).

---

## Étape 2 — Fonctions Stripe (Edge Functions) + secrets (10 min)

Ces fonctions contiennent la logique de paiement. Elles se déploient avec la **CLI
Supabase** (ou via Claude Cowork qui peut lancer ces commandes pour toi).

### 2.a — Récupérer ta clé secrète Stripe (test)

Dans **Stripe → Developers → API keys** (assure-toi d'être en **mode test**, le
bouton en haut à droite). Copie la **Secret key** qui commence par **`sk_test_...`**.
(La « Publishable key » `pk_test_...` n'est pas nécessaire ici.)

### 2.b — Enregistrer les secrets dans Supabase

Depuis un terminal, à la racine du projet :

```bash
# se connecter et pointer sur le projet (ref = hauwxxuxrufbzhwctsqx)
supabase login
supabase link --project-ref hauwxxuxrufbzhwctsqx

# secrets (colle ta vraie clé sk_test_ à la place)
supabase secrets set STRIPE_SECRET_KEY=sk_test_TA_CLE_SECRETE
# le prix Premium est déjà connu du code, mais on peut le fixer explicitement :
supabase secrets set STRIPE_PRICE_ID=price_1U82IDAtMxpgZksHeXLC84Rq
# (STRIPE_WEBHOOK_SECRET viendra à l'étape 3)
```

### 2.c — Déployer les fonctions

```bash
supabase functions deploy create-checkout-session
supabase functions deploy create-portal-session
supabase functions deploy stripe-webhook --no-verify-jwt
```

> Le `--no-verify-jwt` sur **stripe-webhook** est indispensable : Stripe l'appelle
> sans jeton Supabase, sa sécurité vient de la vérification de signature.
> (Le fichier `supabase/config.toml` note déjà ce réglage.)

---

## Étape 3 — Brancher le webhook Stripe (5 min) — **point d'arrêt**

L'URL publique de ton webhook, à donner à Stripe, est :

```
https://hauwxxuxrufbzhwctsqx.supabase.co/functions/v1/stripe-webhook
```

1. Dans **Stripe (mode test) → Developers → Webhooks → Add endpoint**.
2. **Endpoint URL** : colle l'URL ci-dessus.
3. **Select events** : ajoute ces 4 événements —
   - `checkout.session.completed`
   - `customer.subscription.updated`
   - `customer.subscription.deleted`
   - `invoice.payment_failed`
4. Crée l'endpoint, puis copie le **Signing secret** (commence par **`whsec_...`**).
5. Enregistre-le dans Supabase :

   ```bash
   supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_TON_SECRET
   ```

   Puis redéploie la fonction pour qu'elle prenne le secret :

   ```bash
   supabase functions deploy stripe-webhook --no-verify-jwt
   ```

> ⛳️ **C'est le point d'arrêt prévu.** Une fois le webhook créé et le
> `STRIPE_WEBHOOK_SECRET` enregistré, le circuit de paiement est complet.

---

## Étape 4 — Tester le parcours complet (mode test)

1. **Inscription** : crée un compte avec prénom + nom.
   → Dans Supabase (table `profiles`), tu dois voir `trial_ends_at` ≈ dans 14 jours
   et `subscription_status = trialing`. L'app affiche « il te reste 14 jours d'essai ».
2. **Forcer l'expiration** : dans `profiles`, mets `trial_ends_at` dans le passé
   (ex. hier) pour ton compte, recharge l'app → le **paywall** doit apparaître et
   bloquer l'app.
3. **Payer** : clique « S'abonner — 4,99 €/mois » → tu es redirigé vers Stripe
   Checkout → paye avec la **carte de test `4242 4242 4242 4242`**, une date
   d'expiration future et un CVC au hasard.
4. **Déblocage** : au retour, l'app re-vérifie ton statut. Le webhook a mis
   `subscription_status = active` → l'app se débloque. (Vérifie dans `profiles`.)
5. **Sécurité (RLS)** : avec un compte dont l'essai est fini et sans abonnement,
   même en trafiquant le JavaScript, les tables `accounts` / `sessions` / `trades`
   restent inaccessibles tant que le compte n'est pas actif ou en essai.

---

## Ce qui N'EST PAS fait dans ce lot (volontairement)

- Pas de passage en **mode live** (produit / prix / clés / webhook « live » viendront
  après validation en test).
- Pas de découpage gratuit/premium par fonctionnalité : c'est **tout ou rien**
  (essai puis paywall).

---

## Aide-mémoire des secrets Supabase

| Secret | Où le trouver | Rôle |
|---|---|---|
| `STRIPE_SECRET_KEY` | Stripe → Developers → API keys (test), `sk_test_…` | Signer les appels à Stripe |
| `STRIPE_WEBHOOK_SECRET` | Stripe → Developers → Webhooks → ton endpoint, `whsec_…` | Vérifier que le webhook vient bien de Stripe |
| `STRIPE_PRICE_ID` | déjà fourni : `price_1U82IDAtMxpgZksHeXLC84Rq` | Le prix Premium 4,99 €/mois |

`SUPABASE_URL` et `SUPABASE_SERVICE_ROLE_KEY` sont fournis automatiquement par
Supabase aux fonctions : rien à faire.
