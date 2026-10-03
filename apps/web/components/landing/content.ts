/**
 * Copy and assets for the landing page. The copy describes Credence Finance as specified in
 * docs/Architecture.md and docs/CREDENCE_BUILD_GUIDE.md; lengths stay close to the template's so
 * the layout breaks lines where the design does. Figures are the docs' illustrative examples.
 */

const A = "/landing";

export const asset = {
  logo: `${A}/logo-credence.svg`,
  heroVideo: { mp4: `${A}/hero-video.mp4`, webm: `${A}/hero-video.webm`, poster: `${A}/hero-video-poster.jpg` },
  dashboard: {
    src: `${A}/dashboard.png`,
    srcSet: [500, 800, 1080, 1600, 2000]
      .map((w) => `${A}/dashboard-${w}.png ${w}w`)
      .concat(`${A}/dashboard.png 2391w`)
      .join(", "),
    sizes: "(max-width: 2391px) 100vw, 2391px",
  },
  arrowLeft: `${A}/arrow-left.svg`,
  arrowRight: `${A}/arrow-right.svg`,
  handWatch: {
    src: `${A}/hand-watch.png`,
    srcSet: `${A}/hand-watch-500.png 500w, ${A}/hand-watch.png 682w`,
    sizes: "(max-width: 682px) 100vw, 682px",
  },
  watchApp: {
    src: `${A}/watch-app.jpg`,
    srcSet: `${A}/watch-app-500.jpg 500w, ${A}/watch-app.jpg 512w`,
    sizes: "(max-width: 512px) 100vw, 512px",
  },
  user: `${A}/user.svg`,
};

const featureImage = (n: 1 | 2) => ({
  src: `${A}/feature-0${n}.jpg`,
  srcSet: [500, 800, 1080, 1600]
    .map((w) => `${A}/feature-0${n}-${w}.jpg ${w}w`)
    .concat(`${A}/feature-0${n}.jpg 1710w`)
    .join(", "),
  sizes: "(max-width: 1710px) 100vw, 1710px",
});

const sky = {
  src: `${A}/sky.avif`,
  srcSet: [500, 800, 1080]
    .map((w) => `${A}/sky-${w}.avif ${w}w`)
    .concat(`${A}/sky.avif 2880w`)
    .join(", "),
  sizes: "(max-width: 2880px) 100vw, 2880px",
};

export type Image = { src: string; srcSet?: string; sizes?: string };

export const navLinks = [
  { label: "How it works", href: "#features" },
  { label: "Markets", href: "#explore" },
  // TODO: point Risk and Docs at the public risk page and docs site once they are live.
  { label: "Risk", href: "#why-us" },
  { label: "Docs", href: "#features" },
];

export const navCta = { label: "Launch App", href: "/app" };

export const hero = {
  title: "Borrow on Stocks. Keep Your Weekend.",
  body: "Borrow USDC against tokenized stocks and Treasury funds. Nobody is liquidated on a fake weekend price.",
  cta: "Join Waitlist",
};

export const marketClock = {
  title: "Lending That Runs on Market Hours",
  body: "Every rule follows each asset's real market clock. While its exchange is closed, nobody can be liquidated, and a weekend price can lower your collateral's value but never raise it.",
};

/** The marquee: the collateral Credence lends against (two identical rows scroll as one strip). */
export const companyLogos = ["NVDA", "AAPL", "TSLA", "COIN", "MSFT", "SPY", "BENJI", "USTBL"].map((t) => ({
  src: `${A}/ticker-${t.toLowerCase()}.svg`,
  alt: t,
}));

export const featuresHeading = {
  tag: "Features",
  title: "Five Rules Built Around the Market Clock",
  body: "Stocks and Treasury funds stop pricing when their market closes. Credence is designed around that, not in spite of it.",
};

/** Delays are the template's per-card slide-in delays (ms). */
export const features = [
  { icon: `${A}/icon-02.svg`, title: "Borrow USDC", body: "Borrow up to 75% LTV against tokenized stocks, ETFs and Treasury fund shares.", delay: 150 },
  { icon: `${A}/icon-03.svg`, title: "Gap Cover", body: "Insure a loan through one closure instead of cutting your leverage every Friday.", delay: 250 },
  { icon: `${A}/icon-04.svg`, title: "Asset Clock", body: "Knows whether each market is open, closed, halted or reopening. Every rule follows it.", delay: 350 },
  { icon: `${A}/icon-05.svg`, title: "Priced Risk", body: "Premiums come from 10 years of real weekend price gaps for each ticker.", delay: 150 },
  { icon: `${A}/icon-06.svg`, title: "Bell Alerts", body: "App, email and push alerts with exact amounts before every close that needs action.", delay: 250 },
  { icon: `${A}/icon-01.svg`, title: "Fair Auctions", body: "Liquidations clear in uniform-price batch auctions, so being fastest earns nothing.", delay: 350 },
];

export const whyUsHeading = {
  tag: "Why us",
  title: "Weekend Risk, Priced and Paid For",
  body: "Elsewhere, lenders silently carry the Monday gap. Credence prices it per loan and sells it to underwriters paid to hold it.",
};

export const whyUs = [
  {
    title: "No Liquidations While Markets Sleep",
    body: "Nights, weekends, holidays and trading halts pause liquidations. You can always repay or add collateral, at any hour, even if an oracle or keeper is down.",
    image: featureImage(2),
    caption: "Closed means closed",
    imageFirst: false,
  },
  {
    title: "Senior Lenders Are Protected First",
    body: "A first-loss Underwriter Pool absorbs every reopen shortfall before senior lenders, and it only sells cover it can survive across every joint weekend since 2016.",
    image: featureImage(1),
    caption: "Senior by design",
    imageFirst: true,
  },
];

export const explore = {
  tag: "eXPLORE",
  title: "Three Ways to Put Capital to Work",
  body: "Borrow against your stocks, lend to the Senior Vault, or underwrite the weekend gap. Every rate and risk is on-chain.",
};

export type Slide = { icon: string; title: string; body: string; light?: boolean; image?: Image };

const slideSet: Slide[] = [
  {
    icon: `${A}/icon-08.svg`,
    title: "Borrow Against Stocks",
    body: "Keep your NVDA or SPY exposure and borrow USDC. Weeknights need no action, and a risky weekend can be covered instead of sold.",
    image: sky,
  },
  {
    icon: `${A}/icon-07.svg`,
    title: "Underwrite the Gap",
    body: "Hold first-loss capital through each closure. Earn every Gap Cover premium, a share of borrow interest and of penalties.",
    light: true,
  },
  {
    icon: `${A}/icon-09.svg`,
    title: "Lend to the Senior Vault",
    body: "Earn the senior share of borrow interest and withdraw whenever liquidity allows. The clock never locks your deposit.",
  },
];

/** The template repeats the three cards three times. */
export const slides: Slide[] = [...slideSet, ...slideSet, ...slideSet];

export const appleWatch = {
  title: "The Bell on Your Wrist",
  body: "An alert before every risky close, with the exact amount to repay or to cover.",
  cta: { label: "Get Bell alerts", href: "#waitlist" },
};

export const tabsHeading = {
  title: "Everything Runs on the Clock",
  body: "From Friday's Bell to Monday's reopen auction, every step is on-chain, public and checked by the contracts.",
};

export const tabs = [
  { label: "Markets", image: `${A}/tab-transfers.svg`, body: "Isolated markets for NVDA, AAPL, TSLA, COIN, MSFT and SPY tokens, plus tokenized Treasury money funds." },
  { label: "The Bell", image: `${A}/tab-alerts.svg`, body: "Two hours before a risky close, each loan must reach the weekend-safe LTV or carry Gap Cover. Default is auto-cover." },
  { label: "Borrow", image: `${A}/tab-savings.svg`, body: "Deposit stock tokens and borrow USDC up to 75% LTV. Interest accrues every second; repaying is never blocked." },
  { label: "Underwrite", image: `${A}/tab-setup.svg`, body: "Deposit USDC into the first-loss pool. Each closure is an epoch, and you are paid for exactly the risk you carried." },
];

export const testimonials = {
  title: "What Credence promises every user",
  intro: "No reviews yet: Credence is still in testnet. These are the rules its contracts enforce, and each one has a test.",
  items: [
    { name: "— Borrowers", quote: "\"Nobody is liquidated while their asset's market is closed, halted or in a corporate action.\"", delay: 150 },
    { name: "— Senior lenders", quote: "\"You lose money only after the Underwriter Pool and the protocol reserve are both used up.\"", delay: 250 },
    { name: "— Underwriters", quote: "\"You earn the premiums for exactly the closures you carried. Exits settle at the post-weekend price.\"", delay: 150 },
    { name: "— Auction bidders", quote: "\"Every winner pays the same clearing price. Speed, ordering and priority fees are worth nothing.\"", delay: 250 },
  ],
};

export const cta = {
  title: "Keep Your Stocks. Borrow USDC.",
  body: "Credence Finance is launching on Arbitrum. Join the waitlist to get testnet access first.",
  button: { label: "Join Waitlist", href: "#waitlist" },
};

export const footer = {
  newsletter: "Join the waitlist",
  social: [
    { href: "https://ig.com", icon: `${A}/instagram.svg`, label: "Instagram" },
    { href: "https://twitter.com", icon: `${A}/twitter.svg`, label: "Twitter" },
    { href: "mailto:email@dummy.com", icon: `${A}/mail.svg`, label: "Email" },
  ],
  columns: [
    {
      title: "Protocol",
      links: [
        { label: "Features", href: "#features" },
        { label: "Markets", href: "#explore" },
        { label: "Security", href: "#why-us" },
        { label: "Bell alerts", href: "#bell" },
      ],
    },
    {
      title: "Social media",
      links: [
        { label: "Instagram", href: "https://instagram.com" },
        { label: "Facebook", href: "https://fb.com" },
        { label: "Linkedin", href: "https://linkedin.com" },
        { label: "Twitter", href: "https://twitter.com" },
      ],
    },
    {
      // TODO: point these at the published docs and risk page once they exist.
      title: "Resources",
      links: [
        { label: "Documentation", href: "#" },
        { label: "Risk page", href: "#" },
        { label: "Architecture", href: "#" },
        { label: "Status", href: "#" },
      ],
    },
  ],
  credits: [
    { prefix: "Built on", label: "ARBITRUM", href: "https://arbitrum.io/" },
  ],
};
