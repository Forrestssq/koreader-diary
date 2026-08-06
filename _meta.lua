local _ = require("gettext")
return {
    fullname = _("日记"),
    description = _([[弹出全屏输入框，把内容按秒级时间戳追加写入当天的 Markdown 日记文件；可逐条回顾历史日记（长按可编辑或生成二维码）、按天全屏分页浏览、修改或删除旧记录、按时间段导出为一个大 Markdown 文件，并可设定多个每日提醒时间。]]),
}
