# Camelia · Joyería y Accesorios

Tienda (vista clienta) + panel de la dueña. HTML estático, sin build.

## Archivos
- `index.html` — la página completa
- `support.js`, `image-slot.js` — librerías que usa la página
- `assets/` — logo y fotos
- `supabase/schema.sql` — base de datos
- `js/camelia-supabase.js` — conexión a Supabase y compresión de fotos

## Supabase
1. SQL Editor → pegar `supabase/schema.sql` → Run.
2. Settings → API → Exposed schemas → agregar `camelia`.
3. Authentication → Users → crear el usuario de la dueña, y ejecutar la última línea del SQL con su correo.
4. Copiar URL y clave `anon public` en `js/camelia-supabase.js`.

Todo queda en el esquema `camelia` y el bucket `camelia-fotos`; no toca tablas ni archivos de otros locales.
Las fotos se comprimen en el navegador (WebP, máx. 1000 px, < 150 KB) y el bucket rechaza archivos de más de 200 KB.

## Publicar
Sube la carpeta a GitHub y actívalo en GitHub Pages, Netlify o Hostinger.
