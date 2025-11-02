export const emailTheme = {
  body: 'bg-[#07011a] font-sans text-white antialiased',
  canvas: 'bg-[radial-gradient(circle_at_top,_rgba(98,48,178,0.42)_0%,_rgba(15,4,27,0.92)_65%)] px-4 py-12 sm:py-16',
  container:
    'mx-auto max-w-xl rounded-3xl border border-[#ffffff18] bg-[#140629]/92 px-8 py-10 shadow-[0_24px_80px_rgba(138,84,255,0.35)]',
  wordmark:
    'text-center text-[22px] font-semibold uppercase tracking-[0.35em] text-transparent bg-gradient-to-r from-[#f0abfc] via-white to-[#c4b5fd]',
  eyebrow: 'mt-6 text-center text-[11px] uppercase tracking-[0.45em] text-[#c4b5fd]/80',
  heading: 'text-center text-[26px] font-semibold leading-tight text-[#f5d0fe]',
  bodyText: 'text-[15px] leading-7 text-[#ede9fe]',
  mutedText: 'text-sm leading-6 text-[#c4b5fd]',
  tinyText: 'text-xs leading-5 text-[#c4b5fd]/90',
  label: 'text-xs uppercase tracking-[0.35em] text-[#a855f7]',
  card: 'rounded-2xl border border-[#ffffff14] bg-[#1c0f3f]/85 p-6 shadow-[0_18px_60px_rgba(99,102,241,0.28)]',
  softCard: 'rounded-2xl border border-[#ffffff12] bg-[#25114d]/85 p-6 shadow-[0_14px_48px_rgba(99,102,241,0.24)]',
  primaryButton:
    'inline-flex items-center justify-center rounded-full bg-gradient-to-r from-[#f0abfc] via-[#f5d0fe] to-[#c4b5fd] px-8 py-3 text-sm font-semibold text-[#2a0f4d] shadow-[0_14px_45px_rgba(172,93,255,0.35)]',
  secondaryButton:
    'inline-flex items-center justify-center rounded-full border border-[#f5d0fe]/45 bg-transparent px-6 py-3 text-xs font-bold uppercase tracking-[0.35em] text-[#f5d0fe]',
  softButton:
    'inline-flex items-center justify-center rounded-full bg-white/5 px-6 py-2 text-xs font-medium uppercase tracking-[0.25em] text-[#f5d0fe]',
  list: 'mt-4 list-disc space-y-3 pl-5 text-[15px] leading-7 text-[#ede9fe]',
  listBare: 'mt-4 space-y-3 text-[15px] leading-7 text-[#ede9fe]',
  divider: 'my-10 h-px bg-gradient-to-r from-transparent via-[#ffffff26] to-transparent',
  footerText: 'text-center text-xs text-[#c4b5fd]',
  footerLink: 'text-[#f5d0fe]',
};

export type EmailTheme = typeof emailTheme;
