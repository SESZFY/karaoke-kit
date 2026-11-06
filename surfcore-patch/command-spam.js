// 群里的「#sl」这类短指令：只拦非主人、非 @/引用的纯指令，避免模型被刷屏指令带着走。
// 不拦普通话题标签（#B站#）或中文标签；只认 # + ASCII 命令词，可带尾随文本。
const COMMAND_RE = /^[#＃][A-Za-z0-9_]{1,24}(?:[\s，。！？,.!?].{0,80})?$/u

export function isSpamCommandText(text) {
  const s = String(text ?? '').trim();
  if (!s) return false;
  return COMMAND_RE.test(s);
}

// 方括号命令：【唱】空之箱、[sing] xxx、【查询】xxx —— 这类是给外部插件（点歌 / 查询 / 点播）
// 的指令，不是聊天内容。桥接不参与：不入未读、不唤醒、不回复。
// 只认「开头就是方括号、括号内 1~8 个不带标点的词、后面最多 60 字参数」的短消息，
// 长句子、括号后接标点连句的，仍按正常聊天处理。
const BRACKET_COMMAND_RE = /^[【\[［][\u4e00-\u9fa5A-Za-z0-9_\-]{1,8}[】\]］][^，。！？；,\n]{0,60}$/u

export function isBracketCommandText(text) {
  const s = String(text ?? '').trim();
  if (!s) return false;
  if (s.length > 72) return false;
  return BRACKET_COMMAND_RE.test(s);
}
