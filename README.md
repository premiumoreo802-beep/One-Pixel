# ONE PIXEL — multiplayer starter

## What this version includes
- Shared 10,000 × 10,000 logical canvas (100 million possible positions)
- Light gray canvas (#F5F5F5)
- Scroll-wheel zoom, zoom buttons, drag-to-pan
- Color palette and custom HEX picker
- Anonymous Supabase sign-in
- Shared pixel storage and live Postgres change updates
- Server-side 10-second placement cooldown, enforced in a transaction
- Realtime count and viewport-based pixel loading

## Setup (about 10 minutes)
1. Create a project at https://supabase.com.
2. In Supabase Dashboard, open Authentication → Providers and enable **Anonymous Sign-Ins**.
3. Open SQL Editor and run all of `supabase/schema.sql`.
4. In Project Settings → API, copy the Project URL and anon/public key.
5. Paste them into `config.js` as `url` and `anonKey`. Do not use a `service_role` key.
6. Serve this folder from a static web server. For local testing, from this folder run:
   `python3 -m http.server 8000`
   Then open `http://localhost:8000`.
7. Deploy the folder to a static host such as Netlify, Vercel, or Cloudflare Pages.

## Security notes
- Browser users only receive the anon/public key.
- Direct client writes to `pixels` are revoked; pixel placement must call `place_pixel`.
- The database serializes each user's cooldown row with `FOR UPDATE`, so parallel requests cannot bypass the 10-second cooldown.
- Anonymous identities are browser-session identities, not verified people. A determined attacker can create new anonymous identities. For a serious public launch, add CAPTCHA / bot protection and abuse monitoring at the edge.
- The canvas uses sparse storage: it stores only pixels people have placed, not 100 million blank rows.
- The viewport fetch caps each request at 50,000 pixels to avoid trying to download the entire artwork at once.

## Product behavior
- Anyone can overwrite an occupied coordinate, but each successful placement consumes that visitor's 10-second cooldown.
- The total counter counts currently occupied coordinates, not the total historical number of placement actions.
- This is a deployable starter, but it is not live until you configure your own Supabase project and host the files.
