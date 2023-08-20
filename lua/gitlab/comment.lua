local Menu               = require("nui.menu")
local NuiTree            = require("nui.tree")
local Popup              = require("nui.popup")
local job                = require("gitlab.job")
local state              = require("gitlab.state")
local u                  = require("gitlab.utils")
local discussions        = require("gitlab.discussions")
local settings           = require("gitlab.settings")
local M                  = {}

local comment_popup      = Popup(u.create_popup_state("Comment", "40%", "60%"))
local edit_popup         = Popup(u.create_popup_state("Edit Comment", "80%", "80%"))

-- This function will open a comment popup in order to create a comment on the changed/updated line in the current MR
M.create_comment         = function()
  comment_popup:mount()
  settings.set_popup_keymaps(comment_popup, M.confirm_create_comment)
end

-- This function (settings.popup.perform_action) will send the comment to the Go server
M.confirm_create_comment = function(text)
  local relative_file_path = u.get_relative_file_path()
  local current_line_number = u.get_current_line_number()
  if relative_file_path == nil then return end

  -- If leaving a comment on a deleted line, get hash value + proper filename
  local sha = ""
  local is_base_file = relative_file_path:find(".git")
  if is_base_file then -- We are looking at a deletion.
    local _, path = u.split_diff_view_filename(relative_file_path)
    relative_file_path = path
    sha = M.find_deletion_commit(path)
    if sha == "" then
      return
    end
  end

  -- TODO: How can we know whether to specify that the comment is on a line that has been modified,
  -- added, or deleted? Additionally, how will we know which line number to send?
  -- We need an intelligent way of getting this information so that we can send it to the comment
  -- creation endpoint, relates to Issue #25: https://github.com/harrisoncramer/gitlab.nvim/issues/25

  local revision = state.MR_REVISIONS[1]
  local jsonTable = {
    comment = text,
    file_name = relative_file_path,
    line_number = current_line_number,
    base_commit_sha = revision.base_commit_sha,
    start_commit_sha = revision.start_commit_sha,
    head_commit_sha = revision.head_commit_sha,
    type = "modification"
  }

  local json = vim.json.encode(jsonTable)

  job.run_job("comment", "POST", json, function(data)
    vim.notify("Comment created")
    discussions.refresh_tree()
  end)
end

-- This function (settings.discussion_tree.delete_comment) will trigger a popup prompting you to delete the current comment
M.delete_comment         = function()
  local menu = Menu({
    position = "50%",
    size = {
      width = 25,
    },
    border = {
      style = "single",
      text = {
        top = "Delete Comment?",
        top_align = "center",
      },
    },
    win_options = {
      winhighlight = "Normal:Normal,FloatBorder:Normal",
    },
  }, {
    lines = {
      Menu.item("Confirm"),
      Menu.item("Cancel"),
    },
    max_width = 20,
    keymap = {
      focus_next = state.settings.dialogue.focus_next,
      focus_prev = state.settings.dialogue.focus_prev,
      close = state.settings.dialogue.close,
      submit = state.settings.dialogue.submit,
    },
    on_submit = M.send_deletion
  })
  menu:mount()
end

-- This function will actually send the deletion to Gitlab
-- when you make a selection
M.send_deletion          = function(item)
  if item.text == "Confirm" then
    local current_node = state.tree:get_node()

    local note_node = discussions.get_note_node(current_node)
    local root_node = discussions.get_root_node(current_node)
    local note_id = note_node.is_root and root_node.root_note_id or note_node.id

    local jsonTable = { discussion_id = root_node.id, note_id = note_id }
    local json = vim.json.encode(jsonTable)

    job.run_job("comment", "DELETE", json, function(data)
      vim.notify(data.message, vim.log.levels.INFO)
      if not note_node.is_root then
        state.tree:remove_node("-" .. note_id)
        state.tree:render()
      else
        -- We are removing the root node of the discussion,
        -- we need to move all the children around, the easiest way
        -- to do this is to just re-render the whole tree 🤷
        discussions.refresh_tree()
        note_node:expand()
      end
    end)
  end
end

-- This function (settings.discussion_tree.edit_comment) will open the edit popup for the current comment in the discussion tree
M.edit_comment           = function()
  local current_node = state.tree:get_node()
  local note_node = discussions.get_note_node(current_node)
  local root_node = discussions.get_root_node(current_node)

  edit_popup:mount()

  local lines = {} -- Gather all lines from immediate children that aren't note nodes
  local children_ids = note_node:get_child_ids()
  for _, child_id in ipairs(children_ids) do
    local child_node = state.tree:get_node(child_id)
    if (not child_node:has_children()) then
      local line = state.tree:get_node(child_id).text
      table.insert(lines, line)
    end
  end

  local currentBuffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(currentBuffer, 0, -1, false, lines)
  settings.set_popup_keymaps(edit_popup, M.send_edits(tostring(root_node.id), note_node.root_note_id or note_node.id))
end

-- This function sends the edited comment to the Go server
M.send_edits             = function(discussion_id, note_id)
  return function(text)
    local json_table = {
      discussion_id = discussion_id,
      note_id = note_id,
      comment = text
    }
    local json = vim.json.encode(json_table)
    job.run_job("comment", "PATCH", json, function(data)
      vim.notify(data.message, vim.log.levels.INFO)
      M.redraw_text(text)
    end)
  end
end

-- This comment (settings.discussion_tree.toggle_resolved) will toggle the resolved status of the current discussion and send the change to the Go server
M.toggle_resolved        = function()
  local note = state.tree:get_node()
  if not note.resolvable then return end

  local json_table = {
    discussion_id = note.id,
    note_id = note.root_note_id,
    resolved = not note.resolved,
  }

  local json = vim.json.encode(json_table)
  job.run_job("comment", "PATCH", json, function(data)
    vim.notify(data.message, vim.log.levels.INFO)
    M.update_resolved_status(note, not note.resolved)
  end)
end

-- Helpers
M.find_deletion_commit   = function(file)
  local current_line = vim.api.nvim_get_current_line()
  local command = string.format("git log -S '%s' %s", current_line, file)
  local handle = io.popen(command)
  local output = handle:read("*line")
  if output == nil then
    vim.notify("Error reading SHA of deletion commit", vim.log.levels.ERROR)
    return ""
  end
  handle:close()
  local words = {}
  for word in output:gmatch("%S+") do
    table.insert(words, word)
  end

  return words[2]
end

M.update_resolved_status = function(note, mark_resolved)
  local current_text = state.tree.nodes.by_id["-" .. note.id].text
  local target = mark_resolved and 'resolved' or 'unresolved'
  local current = mark_resolved and 'unresolved' or 'resolved'

  local function set_property(key, val)
    state.tree.nodes.by_id["-" .. note.id][key] = val
  end

  local has_symbol = function(s)
    return state.settings.discussion_tree[s] ~= nil and state.settings.discussion_tree[s] ~= ''
  end

  set_property('resolved', mark_resolved)

  if not has_symbol(current) and not has_symbol(target) then return end

  if not has_symbol(current) and has_symbol(target) then
    set_property('text', (current_text .. " " .. state.settings.discussion_tree[target]))
  elseif has_symbol(current) and not has_symbol(target) then
    set_property('text', u.remove_last_chunk(current_text))
  else
    set_property('text', (u.remove_last_chunk(current_text) .. " " .. state.settings.discussion_tree[target]))
  end

  state.tree:render()
end

M.redraw_text            = function(text)
  local current_node = state.tree:get_node()
  local note_node = discussions.get_note_node(current_node)

  local childrenIds = note_node:get_child_ids()
  for _, value in ipairs(childrenIds) do
    state.tree:remove_node(value)
  end

  local newNoteTextNodes = {}
  for bodyLine in text:gmatch("[^\n]+") do
    table.insert(newNoteTextNodes, NuiTree.Node({ text = bodyLine, is_body = true }, {}))
  end

  state.tree:set_nodes(newNoteTextNodes, "-" .. note_node.id)

  state.tree:render()
  local buf = vim.api.nvim_get_current_buf()
  u.darken_metadata(buf, '')
end

return M
