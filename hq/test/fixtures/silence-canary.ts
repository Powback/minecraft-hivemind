// A PLANTED DUPLICATE FOR THE SILENCE CHECK TO FIND.
//
// Not real code. It exists so the check is proven to fail on the shapes it claims to catch -- three
// separate guards went quiet today when code moved under them, and a check nobody has seen fail is
// indistinguishable from one that does nothing.
export async function swallows(call: () => Promise<unknown>) {
  const a = await call().catch(() => null);
  try { await call(); } catch {}
  return a;
}
