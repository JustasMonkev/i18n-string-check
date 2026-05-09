import messages from "../../locales/en.json";

export type TranslationKey = keyof typeof messages;

export function t(key: TranslationKey): string {
  return messages[key];
}
