import { useEffect, useState } from "react";

/** 以網址 # 片段做簡單路由，讓 iPhone 的返回手勢與瀏覽器返回鍵可用。 */
export function useRoute(): string[] {
  const read = () => (location.hash.replace(/^#\/?/, "") || "home").split("/").map(decodeURIComponent);
  const [r, setR] = useState(read);
  useEffect(() => {
    const on = () => setR(read());
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);
  return r;
}

export const go = (...parts: string[]) => {
  location.hash = "#/" + parts.map(encodeURIComponent).join("/");
};
export const back = () => history.back();
