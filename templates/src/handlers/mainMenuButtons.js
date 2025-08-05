// /handlers/mainMenuButtons.js
import { t } from '../i18n.js';
export default function mainMenuButtons(lang) {
  return [
    [{ text: t(lang, "GENERATE_IMAGE"), callback_data: "gen_image" }],
    [{ text: t(lang, "GOTO_SUBMENU"), callback_data: "to_submenu" }],
    [{ text: t(lang, "CHANGE_LANG"), callback_data: "change_lang" }]
  ];
}
