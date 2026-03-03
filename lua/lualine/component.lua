-- Copyright (c) 2020-2021 shadmansaleh
-- MIT license, see LICENSE for more details.

---Unified context passed to **every** lualine callback:
---`update_status`, `fmt`, `cond`, `color` (dynamic), and `on_click`.
---
---Fields marked *optional* are `nil` when the callback is invoked at **init time**
---(e.g. the `color` function is called once per vim-mode during highlight pre-generation).
---All fields are populated at **render time** and in **on_click** handlers.
---@class LualineContext
---@field section string Section letter, e.g. `'a'`, `'b'`, `'c'`
---@field mode string Vim mode without leading `_`, e.g. `'normal'`, `'insert'`, `'visual'`
---@field component_name string Name identifier of the component
---@field winid integer|nil Window ID — `refresh_real_curwin` at render time, `v:mouse_winid` (or last render) for `on_click`, `nil` at color init time
---@field bufnr integer|nil Buffer number in that window — `nil` at color init time
---@field is_focused boolean|integer|nil Whether the statusline is active — `nil` at color init time
---@field prev_component LualineComponent|nil Previous component object in the section (`nil` if first, `nil` at color init time)

---Color value accepted by lualine — an hl-group name, an explicit `{fg, bg, gui}` table,
---or a function called with a `LualineContext` that returns one of those.
---@alias LualineColor
---| string                                                                          # Existing highlight group to link to
---| {fg?: string, bg?: string, gui?: string}                                       # Explicit color table
---| fun(ctx: LualineContext): string|{fg?: string, bg?: string, gui?: string}      # Dynamic color

---Opaque token returned by `LualineComponent:create_hl()`.
---Pass it to `LualineComponent:format_hl()` to get the statusline-formatted highlight string.
---@class LualineHighlightToken
---@field name string Base highlight group name (without mode suffix)
---@field fn function|false Dynamic color function, or `false` when the color is static
---@field no_mode boolean `true` when the group has no per-mode variants
---@field link boolean `true` when the group links to another existing hl group
---@field section string Section letter this token belongs to
---@field options LualineComponentOptions Component options used for color defaults

---All options available to a lualine component.
---Global options (icons_enabled, separators, …) are merged in automatically by the loader.
---@class LualineComponentOptions
---@field [1] string|fun(self: LualineComponent, context: LualineContext): string Component spec: built-in name string, or lambda called with `(self, context)` — **Breaking change**: the second argument was `is_focused` (boolean) prior to the context API; use `context.is_focused` instead
---@field component_name string Unique name for this instance (auto-generated when omitted)
---@field icons_enabled boolean Whether to show icons — inherited from global options (default: `true`)
---@field icon? string|{[1]: string, color?: LualineColor, align?: 'left'|'right'} Icon string or config table
---@field padding? number|{left?: number, right?: number} Spaces around the component (default: `1`)
---@field color? LualineColor Custom color override for this component
---@field separator? string|{left?: string, right?: string} Per-component separator override
---@field cond? fun(context: LualineContext): boolean Return `false` to skip rendering this component entirely
---@field fmt? fun(str: string, component: LualineComponent): string Post-process the rendered string
---@field on_click? fun(clicks: integer, button: string, modifiers: string, context: LualineContext) Mouse click handler (requires Neovim ≥ 0.8)
---@field draw_empty? boolean Render the component even when `update_status()` returns `''` (default: `false`)
---@field self {section: string} Internal metadata injected by the loader
---@field component_separators {left: string, right: string} Inherited global component separators
---@field section_separators {left: string, right: string} Inherited global section separators
---@field globalstatus boolean Inherited global statusline flag

local lualine_require = require('lualine_require')
local require = lualine_require.require

---Base class for all lualine components.
---
---To create a custom component:
---```lua
-----@class MyComponent : LualineComponent
---local MyComponent = require('lualine.component'):extend()
---
---function MyComponent:init(options)
---  MyComponent.super.init(self, options)
---  -- apply component-specific defaults
---  self.options = vim.tbl_deep_extend('keep', self.options, { my_opt = true })
---  -- pre-create highlights that will be reused each render
---  self.my_hl = self:create_hl({ fg = '#ff0000' }, 'my_hint')
---end
---
---function MyComponent:update_status()
---  return 'hello'  -- or read self.context.winid, etc.
---end
---
---return MyComponent
---```
---@class LualineComponent
---@field options LualineComponentOptions Merged options for this instance
---@field context LualineContext Render context, populated by `draw()` before `update_status()` is called
---@field status string Current rendered output string (set during `draw()`)
---@field component_no integer Unique numeric ID for this component instance
---@field default_hl string Statusline highlight string for the owning section
---@field on_click_id integer|nil ID registered in `fn_store` for the click handler
---@field applied_separator string Trailing separator appended during the last `draw()`
---@field color_fn_cache table|nil Cached result from a dynamic `color` function
local M = require('lualine.utils.class'):extend()
local modules = lualine_require.lazy_require {
  highlight = 'lualine.highlight',
  utils_notices = 'lualine.utils.notices',
  fn_store = 'lualine.utils.fn_store',
}

-- Used to provide a unique id for each component
local component_no = 1
function M._reset_components()
  component_no = 1
end

-- variable to store component output for manipulation
M.status = ''

function M:__tostring()
  local str = 'Component: ' .. self.options.component_name
  if self.debug then
    str = str .. '\n---------------------\n' .. vim.inspect(self)
  end
  return str
end

M.__is_lualine_component = true

---Initialize a new component instance. Call `MySub.super.init(self, options)` at the
---start of a subclass `init` before accessing `self.options`.
---@param options LualineComponentOptions
function M:init(options)
  self.options = options or {}
  component_no = component_no + 1
  if not self.options.component_name then
    self.options.component_name = tostring(component_no)
  end
  self.component_no = component_no
  self:set_separator()
  self:create_option_highlights()
  self:set_on_click()
end

---sets the default separator for component based on whether the component
---is in left sections or right sections when separator option is omitted.
function M:set_separator()
  if self.options.separator == nil then
    if self.options.component_separators then
      if self.options.self.section < 'x' then
        self.options.separator = self.options.component_separators.left
      else
        self.options.separator = self.options.component_separators.right
      end
    end
  end
end

---creates hl group from color option
function M:create_option_highlights()
  -- set custom highlights
  if self.options.color then
    self.options.color_highlight = self:create_hl(self.options.color)
  end
  -- setup icon highlight
  if type(self.options.icon) == 'table' and self.options.icon.color then
    self.options.icon_color_highlight = self:create_hl(self.options.icon.color)
  end
end

---Setup on click function so they can be added during drawing.
function M:set_on_click()
  if self.options.on_click ~= nil then
    if vim.fn.has('nvim-0.8') == 0 then
      modules.utils_notices.add_notice(
        '### Options.on_click\nSorry `on_click` can only be used in neovim 0.8 or higher.\n'
      )
      self.options.on_click = nil
      return
    end
    local user_fn = self.options.on_click
    local component_self = self
    self.on_click_id = modules.fn_store.register_fn(self.component_no, function(clicks, button, modifiers)
      -- v:mouse_winid is 0 for global statusline (laststatus=3): fall back to
      -- the winid captured during the last draw() call (refresh_real_curwin).
      local mouse_winid = vim.v.mouse_winid
      local winid = (mouse_winid ~= 0) and mouse_winid
        or (component_self.context and component_self.context.winid)
        or vim.api.nvim_get_current_win()
      local bufnr = vim.fn.winbufnr(winid)
      -- Start from the last render context so all fields (section, mode,
      -- component_name, prev_component, is_focused, …) are present, then
      -- override only the click-time window/buffer which may differ.
      local context = vim.tbl_extend('force', component_self.context or {}, {
        winid = winid,
        bufnr = bufnr > 0 and bufnr or vim.api.nvim_get_current_buf(),
      })
      user_fn(clicks, button, modifiers, context)
    end)
  end
end

---adds spaces to left and right of a component
function M:apply_padding()
  local padding = self.options.padding
  local l_padding, r_padding
  if padding == nil then
    padding = 1
  end
  if type(padding) == 'number' then
    l_padding, r_padding = padding, padding
  elseif type(padding) == 'table' then
    l_padding, r_padding = padding.left, padding.right
  end
  if l_padding then
    if self.status:find('%%#.*#') == 1 then
      -- When component has changed the highlight at beginning
      -- we will add the padding after the highlight
      local pre_highlight = vim.fn.matchlist(self.status, [[\(%#.\{-\}#\)]])[2]
      self.status = pre_highlight .. string.rep(' ', l_padding) .. self.status:sub(#pre_highlight + 1, #self.status)
    else
      self.status = string.rep(' ', l_padding) .. self.status
    end
  end
  if r_padding then
    if self.status:reverse():find('%*%%.*#.*#%%') == 1 then
      -- When component has changed the highlight at the end
      -- we will add the padding before the highlight terminates
      self.status = self.status:sub(1, -3) .. string.rep(' ', r_padding) .. self.status:sub(-2, -1)
    else
      self.status = self.status .. string.rep(' ', r_padding)
    end
  end
end

---applies custom highlights for component
function M:apply_highlights(default_highlight)
  if self.options.color_highlight then
    local hl_fmt
    hl_fmt, M.color_fn_cache = self:format_hl(self.options.color_highlight)
    self.status = hl_fmt .. self.status
  end
  if type(self.options.separator) ~= 'table' and self.status:find('%%#') then
    -- Apply default highlight only when we aren't applying trans sep and
    -- the component has changed it's hl. Since we won't be applying
    -- regular sep in those cases so ending with default hl isn't necessary
    self.status = self.status .. default_highlight
    -- Also put it in applied sep so when sep get striped so does the hl
    self.applied_separator = default_highlight
  end
  -- Prepend default hl when the component doesn't start with hl otherwise
  -- color in previous component can cause side effect
  if not self.status:find('^%%#') then
    self.status = default_highlight .. self.status
  end
end

---apply icon to component (appends/prepends component with icon)
function M:apply_icon()
  local icon = self.options.icon
  if self.options.icons_enabled and icon then
    if type(icon) == 'table' then
      icon = icon[1]
    end
    if
      self.options.icon_color_highlight
      and type(self.options.icon) == 'table'
      and self.options.icon.align == 'right'
    then
      self.status = table.concat {
        self.status,
        ' ',
        self:format_hl(self.options.icon_color_highlight),
        icon,
        self:get_default_hl(),
      }
    elseif self.options.icon_color_highlight then
      self.status = table.concat {
        self:format_hl(self.options.icon_color_highlight),
        icon,
        self:get_default_hl(),
        ' ',
        self.status,
      }
    elseif type(self.options.icon) == 'table' and self.options.icon.align == 'right' then
      self.status = table.concat({ self.status, icon }, ' ')
    else
      self.status = table.concat({ icon, self.status }, ' ')
    end
  end
end

---apply separator at end of component only when
---custom highlights haven't affected background
function M:apply_separator()
  local separator = self.options.separator
  if type(separator) == 'table' then
    if self.options.separator[2] == '' then
      if self.options.self.section < 'x' then
        separator = self.options.component_separators.left
      else
        separator = self.options.component_separators.right
      end
    else
      return
    end
  end
  if separator and #separator > 0 then
    self.status = self.status .. separator
    self.applied_separator = self.applied_separator .. separator
  end
end

---apply transitional separator for the component
function M:apply_section_separators()
  if type(self.options.separator) ~= 'table' then
    return
  end
  if self.options.separator.left ~= nil and self.options.separator.left ~= '' then
    self.status = string.format('%%z{%s}%s', self.options.separator.left, self.status)
    self.strip_previous_separator = true
  end
  if self.options.separator.right ~= nil and self.options.separator.right ~= '' then
    self.status = string.format('%s%%Z{%s}', self.status, self.options.separator.right)
  end
end

---Add on click function description to already drawn item
function M:apply_on_click()
  if self.on_click_id then
    self.status = self:format_fn(self.on_click_id, self.status)
  end
end

---remove separator from tail of this component.
---called by lualine.utils.sections.draw_section to manage unnecessary separators
function M:strip_separator()
  if not self.applied_separator then
    self.applied_separator = ''
  end
  self.status = self.status:sub(1, (#self.status - #self.applied_separator))
  self.applied_separator = nil
  return self.status
end

function M:get_default_hl()
  if self.options.color_highlight then
    return self:format_hl(self.options.color_highlight)
  elseif self.default_hl then
    return self.default_hl
  else
    return modules.highlight.format_highlight(self.options.self.section)
  end
end

---Create a highlight group for the given color and return an opaque token.
---Store the token as an instance field and pass it to `format_hl()` during rendering.
---@param color LualineColor Color definition — hl-group string, `{fg, bg, gui}` table, or dynamic function
---@param hint? string Optional suffix appended to the auto-generated group name (useful for multi-color components)
---@return LualineHighlightToken token Opaque token; pass to `format_hl()` to get the stl string
function M:create_hl(color, hint)
  hint = hint and self.options.component_name .. '_' .. hint or self.options.component_name
  return modules.highlight.create_component_highlight_group(color, hint, self.options, false)
end

---Convert a highlight token into a statusline-formatted `%#HlGroup#` string.
---The correct mode suffix (`_normal`, `_insert`, …) is applied automatically.
---When the token holds a dynamic color function, `self.context` is forwarded so the
---function receives the full `LualineContext` (winid, bufnr, is_focused, mode, …) at render time.
---@param hl_token LualineHighlightToken Token returned by `create_hl()`
---@return string stl Statusline-formatted highlight escape, e.g. `%#lualine_a_normal#`
function M:format_hl(hl_token)
  return modules.highlight.component_format_highlight(hl_token, nil, self.context)
end

---Wrap str with click format for function of id
---@param id integer
---@param str string
---@return string
function M:format_fn(id, str)
  return string.format("%%%d@v:lua.require'lualine.utils.fn_store'.call_fn@%s%%T", id, str)
end

-- luacheck: push no unused args
---Return the string content to display. **Must be overridden** in every component subclass.
---`self.context` is already populated when this is called.
---@param is_focused boolean|integer Whether the statusline is active
---@return string status The text to display (empty string hides the component)
function M:update_status(is_focused) end
-- luacheck: pop

---driver code of the class
---@param default_highlight string default hl group of section where component resides
---@param is_focused boolean|integer whether drawing for active or inactive statusline.
---@param context LualineContext|nil Render context injected by `draw_section()`
---@return string stl formatted rendering string for component
function M:draw(default_highlight, is_focused, context)
  self.status = ''
  self.applied_separator = ''
  self.context = vim.tbl_extend('force', context or {}, {
    is_focused = is_focused,
    component_name = self.options.component_name,
    mode = modules.highlight.get_mode_suffix():sub(2),
  })

  if self.options.cond ~= nil and self.options.cond(self.context) ~= true then
    return self.status
  end
  self.default_hl = default_highlight
  local status = self:update_status(is_focused)
  if self.options.fmt then
    status = self.options.fmt(status or '', self)
  end
  if type(status) == 'string' and (#status > 0 or self.options.draw_empty) then
    self.status = status
    if #status > 0 then
      self:apply_icon()
      self:apply_padding()
    end
    self:apply_on_click()
    self:apply_highlights(default_highlight)
    self:apply_section_separators()
    self:apply_separator()
  end
  return self.status
end

return M
