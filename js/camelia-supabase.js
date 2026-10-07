// Camelia · conexión a Supabase (esquema "camelia", bucket "camelia-fotos").
// Completa URL y ANON_KEY desde Supabase → Settings → API.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

export const SUPABASE_URL = '';      // https://xxxx.supabase.co
export const SUPABASE_ANON_KEY = ''; // clave "anon public"
const BUCKET = 'camelia-fotos';

export const db = SUPABASE_URL ? createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { db: { schema: 'camelia' } }) : null;

export const fotoUrl = path => path && db ? db.storage.from(BUCKET).getPublicUrl(path).data.publicUrl : '';

// Tienda (público)
export const cargarCatalogo = () => db.from('catalogo').select('*').order('featured', { ascending: false });
export const cargarPromo = () => db.from('promo').select('*').eq('id', 1).single();
export const crearPedido = (client, phone, note, items) => db.rpc('crear_pedido', { payload: { client, phone, note, items } });

// Dueña (requiere sesión)
export const entrar = (email, password) => db.auth.signInWithPassword({ email, password });
export const salir = () => db.auth.signOut();
export const cargarProductos = () => db.from('products').select('*').order('created_at', { ascending: false });
export const guardarProducto = p => db.from('products').upsert(p).select().single();
export const borrarProducto = id => db.from('products').delete().eq('id', id);
export const guardarPromo = promo => db.from('promo').update(promo).eq('id', 1);
export const cargarPedidos = () => db.from('orders').select('*, order_lines(*)').order('created_at', { ascending: false });
export const cambiarEstado = (id, status) => db.from('orders').update({ status }).eq('id', id);
export const borrarPedido = id => db.from('orders').delete().eq('id', id);

// Fotos livianas: máx. 1000 px, WebP, se baja la calidad hasta pesar < 150 KB.
export async function comprimirFoto(file, { maxDim = 1000, maxBytes = 150 * 1024 } = {}) {
  const bmp = await createImageBitmap(file);
  let dim = Math.min(maxDim, Math.max(bmp.width, bmp.height));
  for (let intento = 0; intento < 4; intento++) {
    const s = dim / Math.max(bmp.width, bmp.height);
    const c = document.createElement('canvas');
    c.width = Math.round(bmp.width * s); c.height = Math.round(bmp.height * s);
    c.getContext('2d').drawImage(bmp, 0, 0, c.width, c.height);
    for (let q = 0.8; q >= 0.45; q -= 0.07) {
      const blob = await new Promise(r => c.toBlob(r, 'image/webp', q));
      if (blob && blob.size <= maxBytes) { bmp.close?.(); return blob; }
    }
    dim = Math.round(dim * 0.8);
  }
  bmp.close?.();
  throw new Error('No se pudo reducir la foto a menos de 150 KB');
}

export async function subirFoto(productId, file, fotoAnterior) {
  const blob = await comprimirFoto(file);
  const path = `productos/${productId}-${Date.now()}.webp`;
  const { error } = await db.storage.from(BUCKET).upload(path, blob, { contentType: 'image/webp', cacheControl: '31536000' });
  if (error) throw error;
  await db.from('products').update({ photo_path: path }).eq('id', productId);
  if (fotoAnterior) await db.storage.from(BUCKET).remove([fotoAnterior]);
  return { path, url: fotoUrl(path), kb: Math.round(blob.size / 1024) };
}
