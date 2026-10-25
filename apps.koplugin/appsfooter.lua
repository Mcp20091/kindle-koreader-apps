--[[--
A book's status bar (KOReader's footer) in the style of the apps' title bar:
the clock as the apps show it ("11:48 PM", or 24-hour with Apps' 24-hour
clock), items set apart with " · ", and the apps' font (NotoSans), at the
size picked in KOReader. KOReader's own footer settings are left as they
are: with Apps settings > Status bar like the apps off, it is KOReader's again.
]]

local Font = require("ui/font")
local logger = require("logger")

local Footer = {}

local FACE = "./fonts/noto/NotoSans-Regular.ttf"

function Footer.on()
    local s = G_reader_settings:readSetting("apps")
    return not (type(s) == "table" and s.footer_style == false)
end

local function clock()
    local now = os.date("*t")
    if not G_reader_settings:isTrue("twelve_hour_clock") then return string.format("%02d:%02d", now.hour, now.min) end
    return string.format("%d:%02d %s", (now.hour + 11) % 12 + 1, now.min, now.hour < 12 and "AM" or "PM")
end

function Footer.install()
    if Footer.installed then return end
    Footer.installed = true
    local ok, RF = pcall(require, "apps/reader/modules/readerfooter")
    if not ok or not RF or not RF.textGeneratorMap then
        logger.warn("Apps: no reader footer to style")
        return
    end
    local map = RF.textGeneratorMap
    local time = map.time
    if time then
        map.time = function(footer)
            if not Footer.on() then return time(footer) end
            local text = time(footer)
            -- KOReader's own icon or letter before it, then the apps' clock.
            local prefix = text:match("^(%S+) ") and text:match("^(.-)%s*%d") or nil
            return (prefix and prefix ~= "" and (prefix .. " ") or "") .. clock()
        end
    end
    local genSeparator = RF.genSeparator
    RF.genSeparator = function(footer)
        if Footer.on() and footer.settings.items_separator ~= "none" then return " · " end
        return genSeparator(footer)
    end
    local updateFont = RF.updateFooterFont
    RF.updateFooterFont = function(footer)
        updateFont(footer)
        if Footer.on() then Footer.font(footer) end
    end
    local init = RF.init
    RF.init = function(footer, ...)
        local r = init(footer, ...)
        if Footer.on() and footer.footer_text then pcall(Footer.font, footer) end
        return r
    end
end

--- The apps' font, at KOReader's size (KOReader's setting left as it is).
function Footer.font(footer)
    if footer.settings.text_font_face == FACE and not footer.settings.text_font_bold then return end
    local TextWidget = require("ui/widget/textwidget")
    footer.separator_width, footer.filler_space_width = nil, nil
    footer.footer_text_face = Font:getFace(FACE, footer.settings.text_font_size)
    local old = footer.footer_text
    footer.footer_text = TextWidget:new{ text = old.text, face = footer.footer_text_face, bold = false }
    old:free()
    if footer.text_container then footer.text_container[1] = footer.footer_text end
end

return Footer
