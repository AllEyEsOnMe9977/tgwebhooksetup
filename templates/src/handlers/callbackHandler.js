// handlers/callbackHandler.js
import { UserStateManager } from '../db/state.js';
import { UserManager } from '../db/user.js';
import { trackInteraction } from '../db/interaction.js';
import { LANGS, LANG_NAMES, t } from '../i18n.js';
import mainMenuButtons from './mainMenuButtons.js';
import runwareModelConfig from '../services/runwareImageGen_models.js';
import { getActiveInviteLinksMap, checkUserMembership } from '../db/sponsoredInviteLinks.js';
import { safeApiCall } from '../utils/safeApiCall.js';
import { CALLBACK_REACTIONS } from '../utils/reactionsEmos.js';
import { react } from "../utils/react.js";
import { buildModelButtons } from "../utils/buildModelButtons.js";
import { renderUIMessage } from "../utils/renderUIMessage.js";


const { ADMIN_ID } = process.env;
const ADMIN_ID_INT = parseInt(ADMIN_ID, 10) || 0;

export async function handleCallback({ update, tg, tgQueue, res }) {
  const cq = update.callback_query;
  const userId = Number(cq.from.id);
  const chatId = Number(cq.message.chat.id);
  const messageId = Number(cq.message.message_id);
  const data = cq.data;

  // One-time global queue error handler
  if (!tgQueue._hasErrorHandler) {
    tgQueue._hasErrorHandler = true;
    process.on('unhandledRejection', err => {
      console.error('[QUEUE] Unhandled promise rejection in callbackHandler, clearing queue:', err);
      tgQueue.clearQueue();
    });
  }

  try {
    const userInfo = await UserManager.getUser(userId);
    const lang = userInfo?.selected_lang || 'en';

    await trackInteraction({
      user_id: userId,
      chat_id: chatId,
      type: 'callback',
      payload: data,
      message_id: messageId
    });

    // Language selection (user picked a specific language)
    if (data.startsWith('lang_')) {
      await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.CHANGE_LANG_OPEN); // acknowledge tap

      const langCode = data.replace('lang_', '');
      if (LANGS.includes(langCode)) {
        await UserManager.setUserLang(userId, langCode);

        await safeApiCall(
          tgQueue, tg,
          tg.editMessageText.bind(tg),
          [chatId, messageId, t(langCode, 'LANG_SELECTED', { lang: t(langCode, 'LANG_NAME') })],
          chatId
        );

        // celebratory reaction for the selection
        await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.LANG_PICKED, { is_big: true });

        // Show main menu after a short pause
        setTimeout(async () => {
          await safeApiCall(
            tgQueue, tg,
            tg.editMessageText.bind(tg),
            [chatId, messageId, t(langCode, 'MENU_TITLE'), { reply_markup: { inline_keyboard: mainMenuButtons(langCode) } }],
            chatId
          );
          await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.MENU_OPEN);
        }, 800);

        await safeApiCall(
          tgQueue, tg,
          tg.answerCallbackQuery.bind(tg),
          [cq.id, { text: t(langCode, 'LANG_SELECTED', { lang: t(langCode, 'LANG_NAME') }) }],
          chatId
        );

        await UserStateManager.setState(userId, chatId, 'menu', {}, messageId);
        return res.sendStatus(200);
      }
    }

    // Change language menu (open list of languages)
    if (data === 'change_lang') {
      await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.CHANGE_LANG_OPEN);

      const langButtons = LANG_NAMES.map(l => [{ text: l.name, callback_data: `lang_${l.code}` }]);
      await safeApiCall(
        tgQueue, tg,
        tg.editMessageText.bind(tg),
        [chatId, messageId, t(lang, 'LANG_MENU'), { reply_markup: { inline_keyboard: langButtons } }],
        chatId
      );

      await safeApiCall(
        tgQueue, tg,
        tg.answerCallbackQuery.bind(tg),
        [cq.id, { text: t(lang, 'LANG_MENU') }],
        chatId
      );

      await UserStateManager.setState(userId, chatId, 'lang_select', {}, messageId);
      return res.sendStatus(200);
    }

    // Generate image flow start – sponsor gating first
    if (data === 'gen_image') {
      await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.GEN_IMAGE_ENTRY, { is_big: true });

      const membershipCheck = await checkUserMembership(tg, userId);

      if (membershipCheck?.allJoined) {
        const models = runwareModelConfig.aiModelConfigs || [];
        const modelButtons = buildModelButtons(models, lang);

        const newMsgId = await renderUIMessage({
          tg, tgQueue, chatId,
          prevMessageId: messageId,
          text: t(lang, 'SELECT_MODEL'),
          keyboard: modelButtons
        });

        await UserStateManager.setState(userId, chatId, 'model_select', {}, newMsgId);
        await react(tgQueue, tg, chatId, newMsgId, CALLBACK_REACTIONS.MODEL_LIST_SHOWN);
      } else {
        await showSponsorChannels(tg, tgQueue, chatId, messageId, lang, safeApiCall);
        await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.SPONSOR_REQUIRED);

        await UserStateManager.setState(userId, chatId, 'model_select', { needsSponsorCheck: true }, messageId);
      }

      await safeApiCall(tgQueue, tg, tg.answerCallbackQuery.bind(tg), [cq.id], chatId);
      return res.sendStatus(200);
    }

    // "I joined all" button – re-check membership
    if (data === 'check_membership') {
      const membershipCheck = await checkUserMembership(tg, userId);

      if (membershipCheck?.allJoined) {
        await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.MEMBERSHIP_OK, { is_big: true });

        const models = runwareModelConfig.aiModelConfigs || [];
        const modelButtons = buildModelButtons(models, lang);

        const newMsgId = await renderUIMessage({
          tg, tgQueue, chatId,
          prevMessageId: messageId,
          text: t(lang, 'SELECT_MODEL'),
          keyboard: modelButtons
        });

        await UserStateManager.setState(userId, chatId, 'model_select', {}, newMsgId);
        await react(tgQueue, tg, chatId, newMsgId, CALLBACK_REACTIONS.MODEL_LIST_SHOWN);

        await safeApiCall(
          tgQueue, tg,
          tg.answerCallbackQuery.bind(tg),
          [cq.id, { text: t(lang, 'SELECT_MODEL') }],
          chatId
        );
      } else {
        const notJoinedChannels = (membershipCheck?.results ?? [])
          .filter(r => !r.joined)
          .map(r => r.name)
          .join(', ');

        await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.MEMBERSHIP_MISSING);

        await safeApiCall(
          tgQueue, tg,
          tg.answerCallbackQuery.bind(tg),
          [cq.id, { text: t(lang, 'NOT_ALL_JOINED', { channels: notJoinedChannels }), show_alert: true }],
          chatId
        );
      }
      return res.sendStatus(200);
    }

    // Model chosen → ask for prompt (with sponsor double-check if needed)
    if (data.startsWith('choose_model_')) {
      const modelId = data.replace('choose_model_', '');

      const currentState = await UserStateManager.getState(userId, chatId);
      if (currentState?.data?.needsSponsorCheck) {
        const membershipCheck = await checkUserMembership(tg, userId);
        if (!membershipCheck?.allJoined) {
          const notJoinedChannels = (membershipCheck?.results ?? [])
            .filter(result => !result.joined)
            .map(result => result.name)
            .join(', ');

          await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.MEMBERSHIP_MISSING);

          await safeApiCall(
            tgQueue, tg,
            tg.answerCallbackQuery.bind(tg),
            [cq.id, { text: t(lang, 'MUST_JOIN_FIRST', { channels: notJoinedChannels }), show_alert: true }],
            chatId
          );
          return res.sendStatus(200);
        }
      }

      // Render the "ask for prompt" as a fresh message (or edit, depending on renderUIMessage),
      // and remember its message_id so we can delete it once the user sends the prompt.
      const promptMsgId = await renderUIMessage({
        tg, tgQueue, chatId,
        prevMessageId: messageId,
        text: t(lang, 'ASK_FOR_PROMPT', { model: modelId }),
        keyboard: [[{ text: t(lang, 'BACK_BUTTON'), callback_data: 'gen_image' }]],
        parse_mode: 'HTML'
      });

      await UserStateManager.setState(
        userId,
        chatId,
        'awaiting_prompt',
        { modelId, last_prompt_message_id: promptMsgId },
        promptMsgId
      );

      await react(tgQueue, tg, chatId, promptMsgId, CALLBACK_REACTIONS.PROMPT_AWAITING, { is_big: true });

      await safeApiCall(
        tgQueue, tg,
        tg.answerCallbackQuery.bind(tg),
        [cq.id, { text: t(lang, 'ASK_FOR_PROMPT_SHORT') ?? t(lang, 'ASK_FOR_PROMPT', { model: modelId }) }],
        chatId
      );

      return res.sendStatus(200);
    }

    // Submenu or main menu toggle
    if (data === 'to_submenu' || data === 'to_mainmenu') {
      if (data === 'to_submenu') {
        await UserStateManager.setState(userId, chatId, 'submenu', { at: new Date() }, messageId);

        await safeApiCall(
          tgQueue, tg,
          tg.editMessageText.bind(tg),
          [
            chatId,
            messageId,
            t(lang, 'SUBMENU_TITLE'),
            { reply_markup: { inline_keyboard: [[{ text: t(lang, 'BACK_BUTTON'), callback_data: 'to_mainmenu' }]] } }
          ],
          chatId
        );

        await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.SUBMENU_OPEN);
      } else {
        await UserStateManager.setState(userId, chatId, 'menu', {}, messageId);

        await safeApiCall(
          tgQueue, tg,
          tg.editMessageText.bind(tg),
          [chatId, messageId, t(lang, 'MENU_TITLE'), { reply_markup: { inline_keyboard: mainMenuButtons(lang) } }],
          chatId
        );

        await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.MENU_OPEN);
      }

      await safeApiCall(
        tgQueue, tg,
        tg.answerCallbackQuery.bind(tg),
        [cq.id],
        chatId
      );

      return res.sendStatus(200);
    }

    // Generic callback acknowledgment (unknown/other buttons)
    await UserStateManager.setState(userId, chatId, 'menu', { last_callback: data }, messageId);

    await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.GENERIC_ACK);

    await safeApiCall(
      tgQueue, tg,
      tg.answerCallbackQuery.bind(tg),
      [cq.id],
      chatId
    );

    return res.sendStatus(200);

  } catch (err) {
    console.error('[handleCallback] error:', err);
    try {
      await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.ERROR, { is_big: true });

      await safeApiCall(
        tgQueue, tg,
        tg.sendMessage.bind(tg),
        [chatId, 'Sorry, something went wrong. Please try again later.'],
        chatId
      );
      await safeApiCall(
        tgQueue, tg,
        tg.answerCallbackQuery.bind(tg),
        [cq.id],
        chatId
      );
    } catch {}
    return res.sendStatus(200);
  }
}

// Helper function to show sponsor channels with invite links
async function showSponsorChannels(tg, tgQueue, chatId, messageId, lang, safeApiCall) {
  const sponsorChannels = await getActiveInviteLinksMap();
  if (!Array.isArray(sponsorChannels)) return;
  if (sponsorChannels.length === 0) return;

  const channelButtons = [];
  for (const channel of sponsorChannels) {
    if (!channel || !channel.invite_link) continue;
    channelButtons.push([{
      text: `📢 ${channel.chat_title}`,
      url: channel.invite_link
    }]);
  }
  channelButtons.push([{
    text: t(lang, 'I_JOINED_ALL'),
    callback_data: 'check_membership'
  }]);
  channelButtons.push([{
    text: t(lang, 'BACK_BUTTON'),
    callback_data: 'to_mainmenu'
  }]);

  const message = t(lang, 'JOIN_CHANNELS_MESSAGE');

  // Nudge user with a sponsor-related reaction before updating the message
  await react(tgQueue, tg, chatId, messageId, CALLBACK_REACTIONS.SPONSOR_REQUIRED);

  await safeApiCall(
    tgQueue, tg,
    tg.editMessageText.bind(tg),
    [chatId, messageId, message, { reply_markup: { inline_keyboard: channelButtons } }],
    chatId
  );
}
