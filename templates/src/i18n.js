export const TRANSLATIONS = {
  en: {
    WELCOME: "👋 Welcome! You're now using the bot.",
    MENU_TITLE: "Main menu:\n\nChoose:",
    LANG_NAME: "English",
    SELECT_LANG: "Please select your language:",
    LANG_SELECTED: "Language set to English!",
    SUBMENU_TITLE: "You are in the submenu.\n\nPress to go back.",
    CHANGE_LANG: "🌐 Change Language",
    LANG_MENU: "Please select your language:",
    LANG_SELECTED: "Language changed to {lang}!",    
    BACK_BUTTON: "⬅️ Back to Main Menu",
    GOTO_SUBMENU: "Go to Submenu",
    STATE_RESET: "State reset. Send /menu to start again.",
    EDITED: "✏️ This message was edited via /editlast!",
    EDITED_CONFIRM: "Last menu message edited!",
    DELETED_CONFIRM: "Last menu message deleted!",
    NO_EDITABLE: "No recent menu message to edit.",
    NO_DELETABLE: "No recent menu message to delete.",
    NEW_USER: "🆕 New user started the bot!",
    BOT_STARTED: "🚀 Bot started at {time}",
    LANGUAGE_CHANGED: "🌐 Language changed!",
    ECHO: '👋 Hello! You said: "{text}"',
    // ... Add more keys as needed
  },
  fa: {
    WELCOME: "👋 خوش آمدید! شما اکنون از ربات استفاده می‌کنید.",
    MENU_TITLE: "منوی اصلی:\n\nانتخاب کنید:",
    LANG_NAME: "فارسی",
    SELECT_LANG: "لطفاً زبان خود را انتخاب کنید:",
    CHANGE_LANG: "🌐 تغییر زبان",
    LANG_MENU: "لطفاً زبان خود را انتخاب کنید:",
    LANG_SELECTED: "زبان به {lang} تغییر کرد!",    
    SUBMENU_TITLE: "شما در زیرمنو هستید.\n\nبرای بازگشت فشار دهید.",
    BACK_BUTTON: "⬅️ بازگشت به منوی اصلی",
    GOTO_SUBMENU: "رفتن به زیرمنو",
    STATE_RESET: "وضعیت بازنشانی شد. دوباره /menu را ارسال کنید.",
    EDITED: "✏️ این پیام با /editlast ویرایش شد!",
    EDITED_CONFIRM: "آخرین پیام منو ویرایش شد!",
    DELETED_CONFIRM: "آخرین پیام منو حذف شد!",
    NO_EDITABLE: "هیچ پیام منوی قابل ویرایش وجود ندارد.",
    NO_DELETABLE: "هیچ پیام منوی قابل حذف وجود ندارد.",
    NEW_USER: "🆕 کاربر جدید ربات را شروع کرد!",
    BOT_STARTED: "🚀 ربات شروع شد در {time}",
    LANGUAGE_CHANGED: "🌐 زبان تغییر کرد!",
    ECHO: '👋 سلام! توگفتی: "{text}"',
    LANG_SELECTED: "زبان شما به فارسی تنظیم شد!",
    // ... Add more keys as needed
  }
};

// Helper to fetch and interpolate translation
export const LANGS = Object.keys(TRANSLATIONS);
export const LANG_NAMES = LANGS.map(l => ({
  code: l,
  name: TRANSLATIONS[l].LANG_NAME
}));
export function t(lang = "en", key, vars = {}) {
  let msg = TRANSLATIONS[lang]?.[key] || TRANSLATIONS.en[key] || key;
  Object.keys(vars).forEach(k => {
    msg = msg.replaceAll(`{${k}}`, vars[k]);
  });
  return msg;
}