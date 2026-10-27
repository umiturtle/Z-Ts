export {};
declare global {
  interface Window {
    __ztsPostMessage?: (message: string) => void;
  }
}
