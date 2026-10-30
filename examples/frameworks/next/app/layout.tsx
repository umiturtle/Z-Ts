import './globals.css';
export const metadata = { title: 'Z-Ts — framework demo' };
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (<html lang="ja"><body>{children}</body></html>);
}
