import { UserStateManager } from '../db/state.js';
import { UserManager } from '../db/user.js';
import { trackInteraction } from '../db/interaction.js';
import { LANGS, LANG_NAMES, t } from '../i18n.js';

function mainMenuButtons(lang) {
  return [
    [{ text: t(lang, "GOTO_SUBMENU"), callback_data: "to_submenu" }],
    [{ text: t(lang, "CHANGE_LANG"), callback_data: "change_lang" }]
  ];
}

export async function handleCallback({ update, tg, tgQueue, res }) {
  const cq = update.callback_query;
  const userId = Number(cq.from.id);
  const chatId = Number(cq.message.chat.id);
  const messageId = Number(cq.message.message_id);
  const data = cq.data;
  const userInfo = await UserManager.getUser(userId);
  const lang = userInfo?.selected_lang || "en";

  await trackInteraction({
    user_id: userId,
    chat_id: chatId,
    type: 'callback',
    payload: data,
    message_id: messageId
  });

  // Helper for all bot API calls (with queue)
  async function safeApiCall(fn, args = [], fallbackText = null) {
    try {
      return await tgQueue.enqueue(fn, args, chatId);
    } catch (err) {
      const msg = String(err);
      if (
        msg.includes('message is not modified') ||
        msg.includes('message to delete not found')
      ) {
        return;
      }
      if (chatId && fallbackText) {
        try { await tgQueue.enqueue(tg.sendMessage.bind(tg), [chatId, fallbackText], chatId); } catch (_) {}
      }
    }
  }

  if (data.startsWith("lang_")) {
    const langCode = data.replace("lang_", "");
    if (LANGS.includes(langCode)) {
      await UserManager.setUserLang(userId, langCode);
      await safeApiCall(
        tg.editMessageText.bind(tg),
        [chatId, messageId, t(langCode, "LANG_SELECTED", { lang: t(langCode, "LANG_NAME") })]
      );
      setTimeout(async () => {
        await safeApiCall(
          tg.editMessageText.bind(tg),
          [chatId, messageId, t(langCode, "MENU_TITLE"), {
            reply_markup: { inline_keyboard: mainMenuButtons(langCode) }
          }]
        );
      }, 800);
      await safeApiCall(tg.answerCallbackQuery.bind(tg), [cq.id]);
      await UserStateManager.setState(userId, chatId, 'menu', {}, messageId);
      return res.sendStatus(200);
    }
  }

  if (data === 'change_lang') {
    const langButtons = LANG_NAMES.map(l => [
      { text: l.name, callback_data: `lang_${l.code}` }
    ]);
    await safeApiCall(
      tg.editMessageText.bind(tg),
      [chatId, messageId, t(lang, "LANG_MENU"), {
        reply_markup: { inline_keyboard: langButtons }
      }]
    );
    await safeApiCall(tg.answerCallbackQuery.bind(tg), [cq.id]);
    await UserStateManager.setState(userId, chatId, 'lang_select', {}, messageId);
    return res.sendStatus(200);
  }

  if (data === 'to_submenu' || data === 'to_mainmenu') {
    if (data === 'to_submenu') {
      await UserStateManager.setState(userId, chatId, 'submenu', { at: new Date() }, messageId);
      await safeApiCall(
        tg.editMessageText.bind(tg),
        [chatId, messageId, t(lang, 'SUBMENU_TITLE'), {
          reply_markup: { inline_keyboard: [[{ text: t(lang, 'BACK_BUTTON'), callback_data: 'to_mainmenu' }]] }
        }]
      );
    } else if (data === 'to_mainmenu') {
      await UserStateManager.setState(userId, chatId, 'menu', {}, messageId);
      await safeApiCall(
        tg.editMessageText.bind(tg),
        [chatId, messageId, t(lang, 'MENU_TITLE'), {
          reply_markup: { inline_keyboard: mainMenuButtons(lang) }
        }]
      );
    }
    await safeApiCall(
      tg.answerCallbackQuery.bind(tg),
      [cq.id],
    );
    return res.sendStatus(200);
  }

  // generic callback
  await UserStateManager.setState(userId, chatId, 'menu', { last_callback: data }, messageId);
  await safeApiCall(
    tg.answerCallbackQuery.bind(tg),
    [cq.id, { text: `Pressed: ${data}` }]
  );
  return res.sendStatus(200);
}
