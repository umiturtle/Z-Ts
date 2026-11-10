export {};
declare global {
  interface Window {
    __ztsPostMessage?: (message: string) => void;
    __ZTS_ZIG__?: {
      mount(): void;
      probe(): Promise<{ seal: string; count: number }>;
      step(delta: number): Promise<{ seal: string; count: number }>;
    };
  }
}
