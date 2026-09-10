-- luacheck: globals vim
-- グローバル変数として公開(Vimスクリプトから呼び出す)
-- CopilotC-Nvim/CopilotChat.nvim
_G.copilot_chat_setup = function()
  local base = require("CopilotChat.config.providers").copilot
  -- OpenAI 互換エンドポイント(Anthropic/Groq)は空の tools 配列(tools: [])を
  -- 400 invalid_request_error で弾く。copilot の prepare_input をラップし、
  -- tools が空なら省く。関数/エージェント使用時は tools がちゃんと乗る。
  local function prepare_input(inputs, opts)
    local request, headers = base.prepare_input(inputs, opts)
    if type(request) == "table" then
      -- 空 tools 配列(tools: [])は 400 で弾かれるので省く
      if request.tools and #request.tools == 0 then
        request.tools = nil
      end
      -- Claude 4.x 系は temperature と top_p の併用を 400 で弾く。
      -- プラグインは top_p=1(実質デフォルト)を常にセットするので、これを落として
      -- temperature 側を残す。Groq でも top_p=1 除去は無害。
      request.top_p = nil
    end
    return request, headers
  end

  require("CopilotChat").setup({
    -- 応答完了時にプラグインが startinsert する(ui/chat.lua Chat:finish)ので false。
    -- チャットウィンドウに入った時の自動 insert は下の BufEnter autocmd で行う。
    auto_insert_mode = false,

    ---------------------------------------------------------------------------
    -- Default configuration for Copilot Chat
    ---------------------------------------------------------------------------
    -- -- Shared config starts here (can be passed to functions at runtime and configured via setup function)

    -- system_prompt = "COPILOT_INSTRUCTIONS", -- System prompt to use (can be specified manually in prompt via /).
    system_prompt = [[
      分かりやすく具体的に、必ず日本語で応答してください。
    ]],

    -- model = "gpt-4.1", -- Default model to use, see ':CopilotChatModels' for available models (can be specified manually in prompt via $).
    -- model = "gpt-5.5",
    -- model = "claude-sonnet-4.6",
    -- model = "grok-code-fast-1",
    -- model = "claude-haiku-4-5",
    -- プラグイン既定は gpt-5-mini。reasoning 系で体感が重いので Groq の最速モデルに寄せる。
    -- 重くしたい時はプロンプト内 $ で都度切替:
    --   $openai/gpt-oss-20b (推論が要る時) / $claude-sonnet-4-6 / $gpt-5.5
    -- model = "llama-3.1-8b-instant",
    -- model = "llama-3.3-70b-versatile",
    -- model = "openai/gpt-oss-20b",
    model = "openai/gpt-oss-120b",

    -- agent = "copilot", -- Default agent to use, see ':CopilotChatAgents' for available agents (can be specified manually in prompt via @).
    -- context = nil, -- Default context or array of contexts to use (can be specified manually in prompt via #).
    -- sticky = nil, -- Default sticky prompt or array of sticky prompts to use at start of every new chat.
    -- -- sticky = {
    -- --   "@models Using Mistral-small",
    -- --   "#files",
    -- -- },

    -- temperature = 0.1, -- GPT result temperature
    -- headless = false, -- Do not write to chat buffer and use history (useful for using custom processing)
    -- stream = nil, -- Function called when receiving stream updates (returned string is appended to the chat buffer)
    -- callback = nil, -- Function called when full response is received (retuned string is stored to history)
    -- remember_as_sticky = true, -- Remember model/agent/context as sticky prompts when asking questions

    -- -- default selection
    -- -- see select.lua for implementation
    -- selection = select.visual,

    -- -- default window options
    -- window = {
    --   layout = "vertical", -- 'vertical', 'horizontal', 'float', 'replace', or a function that returns the layout
    --   width = 0.5, -- fractional width of parent, or absolute width in columns when > 1
    --   height = 0.5, -- fractional height of parent, or absolute height in rows when > 1
    --   -- Options below only apply to floating windows
    --   relative = "editor", -- 'editor', 'win', 'cursor', 'mouse'
    --   border = "single", -- 'none', single', 'double', 'rounded', 'solid', 'shadow'
    --   row = nil, -- row position of the window, default is centered
    --   col = nil, -- column position of the window, default is centered
    --   title = "Copilot Chat", -- title of chat window
    --   footer = nil, -- footer of chat window
    --   zindex = 1, -- determines if window is on top or below other floating windows
    -- },

    -- show_help = true, -- Shows help message as virtual lines when waiting for user input
    -- highlight_selection = true, -- Highlight selection
    -- highlight_headers = true, -- Highlight headers in chat, disable if using markdown renderers (like render-markdown.nvim)
    -- references_display = "virtual", -- 'virtual', 'write', Display references in chat as virtual text or write to buffer
    -- auto_follow_cursor = true, -- Auto-follow cursor in chat
    -- auto_insert_mode = false, -- Automatically enter insert mode when opening window and on new prompt
    -- insert_at_end = false, -- Move cursor to end of buffer when inserting text
    -- clear_chat_on_new_prompt = false, -- Clears chat on every new prompt

    -- -- Static config starts here (can be configured only via setup function)

    -- debug = false, -- Enable debug logging (same as 'log_level = 'debug')
    -- log_level = "info", -- Log level to use, 'trace', 'debug', 'info', 'warn', 'error', 'fatal'
    -- proxy = nil, -- [protocol://]host[:port] Use this proxy
    -- allow_insecure = false, -- Allow insecure server connections

    -- chat_autocomplete = true, -- Enable chat autocompletion (when disabled, requires manual `mappings.complete` trigger)

    -- log_path = vim.fn.stdpath("state") .. "/CopilotChat.log", -- Default path to log file
    -- history_path = vim.fn.stdpath("data") .. "/copilotchat_history", -- Default path to stored history

    -- question_header = "# User ", -- Header to use for user questions
    -- answer_header = "# Copilot ", -- Header to use for AI answers
    -- error_header = "# Error ", -- Header to use for errors
    -- separator = "───", -- Separator to use in chat

    -- -- default providers
    -- -- see config/providers.lua for implementation
    -- providers = {
    --   copilot = {},
    --   github_models = {},
    --   copilot_embeddings = {},
    -- },
    --
    -- Copilot を経由せず、各ベンダの OpenAI 互換エンドポイント(/v1/chat/completions)を
    -- 直接叩くカスタムプロバイダ。リクエスト/レスポンス形式は OpenAI 互換なので
    -- copilot の prepare_input/prepare_output をそのまま流用できる。
    -- 既定の copilot プロバイダはディープマージで残るため、引き続き併用可能。
    --
    -- モデル id は素のまま(provider サフィックス無し)。理由:
    --  1. provider はアルファベット順処理で、同名 id が衝突したとき後勝ちで ':provider' が
    --     付く仕様(client.lua)。anthropic は最先頭で勝つし、groq のモデル(Llama/gpt-oss 等)は
    --     Copilot 側に存在しないので、そもそも衝突しない=素の id のまま解決される。
    --  2. プロンプトのインライン指定 $model は ':' を含めず拾う仕様(prompts.lua の WORD)なので、
    --     ':provider' 付き id はインライン指定できない。素の id なら $claude-sonnet-4-6 で切替可能。
    -- どの provider のモデルかは :CopilotChatModels の一覧に provider 名が表示されるので判別できる。
    providers = {
      -- Anthropic API 直叩き。
      anthropic = {
        get_url = function()
          return "https://api.anthropic.com/v1/chat/completions"
        end,
        get_headers = function()
          local key = os.getenv("COPILOT_ANTHROPIC_API_KEY")
          if not key or key == "" then
            error("COPILOT_ANTHROPIC_API_KEY が未設定です。")
          end
          return {
            ["Authorization"] = "Bearer " .. key,
          }
        end,
        get_models = function()
          return {
            {
              id = "claude-haiku-4-5", -- 最安・最速($1/$5 per MTok)。翻訳/構文解析向き
              name = "Claude Haiku 4.5",
              tokenizer = "o200k_base", -- 互換用の近似トークナイザ
              max_input_tokens = 200000,
              max_output_tokens = 32000,
              streaming = true,
              tools = true,
            },
            {
              id = "claude-sonnet-4-6", -- バランス型($3/$15 per MTok)
              name = "Claude Sonnet 4.6",
              tokenizer = "o200k_base",
              max_input_tokens = 200000,
              max_output_tokens = 32000,
              streaming = true,
              tools = true,
            },
            {
              id = "claude-opus-4-8", -- 最高性能・最高価格($5/$25 per MTok)
              name = "Claude Opus 4.8",
              tokenizer = "o200k_base",
              max_input_tokens = 200000,
              max_output_tokens = 32000,
              streaming = true,
              tools = true,
            },
          }
        end,
        prepare_input = prepare_input,
        prepare_output = base.prepare_output,
      },

      -- Groq API 直叩き(LPU で OSS モデルを超高速・激安に実行)。OpenAI 互換。
      -- ※ xAI の "Grok" とは別物。
      -- キー未設定なら認証に失敗してモデル一覧に出ないだけ(pcall で握られる)で害はない。
      -- モデル id は入れ替わりが早いので、出ない/増やしたい時は console.groq.com/docs/models で確認。
      --
      -- token 数は Groq の TPM(tokens per minute)制限に合わせて絞ること。Groq は
      -- 「prompt_tokens + max_tokens」を TPM に合算して数えるので、max_output_tokens を
      -- 大きく取るだけで実際の送信量と無関係に 413 rate_limit_exceeded になる。
      -- (32000 を宣言していた頃は prompt が 1000 token でも常に 33k 要求扱いで全弾 413)
      -- 無料枠(service tier: on_demand)の TPM: llama-8b=6000 / llama-70b=12000 / gpt-oss=8000。
      -- x-ratelimit-limit-tokens レスポンスヘッダで現在値を確認できる。
      groq = {
        get_url = function()
          return "https://api.groq.com/openai/v1/chat/completions"
        end,
        get_headers = function()
          local key = os.getenv("GROQ_API_KEY")
          if not key or key == "" then
            error("GROQ_API_KEY が未設定です。")
          end
          return {
            ["Authorization"] = "Bearer " .. key,
          }
        end,
        get_models = function()
          return {
            {
              id = "llama-3.1-8b-instant", -- 最安・最速。翻訳/構文解析ならこれで十分
              name = "Llama 3.1 8B Instant (Groq)",
              tokenizer = "o200k_base",
              max_input_tokens = 2500, -- TPM 6000: input 2500 + output 3000 で収める
              max_output_tokens = 3000,
              streaming = true,
              tools = true,
            },
            {
              id = "llama-3.3-70b-versatile", -- 汎用・高品質
              name = "Llama 3.3 70B Versatile (Groq)",
              tokenizer = "o200k_base",
              max_input_tokens = 6000, -- TPM 12000
              max_output_tokens = 5000,
              streaming = true,
              tools = true,
            },
            {
              id = "openai/gpt-oss-20b", -- 速度と賢さのバランス。120b より軽い
              name = "GPT-OSS 20B (Groq)",
              tokenizer = "o200k_base",
              max_input_tokens = 3500, -- TPM 8000
              max_output_tokens = 4000,
              streaming = true,
              tools = true,
            },
            {
              id = "openai/gpt-oss-120b", -- 推論強め(OpenAI のオープンモデル)
              name = "GPT-OSS 120B (Groq)",
              tokenizer = "o200k_base",
              max_input_tokens = 3500, -- TPM 8000
              max_output_tokens = 4000,
              streaming = true,
              tools = true,
            },
          }
        end,
        prepare_input = prepare_input,
        prepare_output = base.prepare_output,
      },
    },

    -- -- default contexts
    -- -- see config/contexts.lua for implementation
    -- contexts = {
    --   buffer = {},
    --   buffers = {},
    --   file = {},
    --   files = {},
    --   git = {},
    --   url = {},
    --   register = {},
    --   quickfix = {},
    --   system = {},
    -- },
    --
    -- -- default prompts
    -- -- see config/prompts.lua for implementation
    prompts = {
      ExplainJp = {
        prompt = "これなに？",
        system_prompt = "あなたは優秀なプログラマーです。",
        mapping = "<Leader>,",
        description = "what's this?",
      },
      LangAssist = {
        prompt = "選択されたテキストを判定し日本語で解答してください。英語の場合は文法・表現を添削して改善版を提示してください。日本語の場合は自然な英語に翻訳してください。結果には、文法の説明、使えるイディオムや慣用句、より自然な表現の提案も含めてください。",
        system_prompt = "あなたはプロの英語ネイティブ翻訳者・校正者です。",
        -- TODO: sl: apps/vim/.vim/conf.d/101_mapping.vim move window is mapped.
        mapping = "<Leader>.",
        description = "英語添削 / 日本語→英訳",
      },
    },
    -- prompts = {
    --   Explain = {
    --     prompt = "Write an explanation for the selected code as paragraphs of text.",
    --     system_prompt = "COPILOT_EXPLAIN",
    --   },
    --   Review = {
    --     prompt = "Review the selected code.",
    --     system_prompt = "COPILOT_REVIEW",
    --   },
    --   Fix = {
    --     prompt = "There is a problem in this code. Identify the issues and rewrite the code with fixes. Explain what was wrong and how your changes address the problems.",
    --   },
    --   Optimize = {
    --     prompt = "Optimize the selected code to improve performance and readability. Explain your optimization strategy and the benefits of your changes.",
    --   },
    --   Docs = {
    --     prompt = "Please add documentation comments to the selected code.",
    --   },
    --   Tests = {
    --     prompt = "Please generate tests for my code.",
    --   },
    --   Commit = {
    --     prompt = "Write commit message for the change with commitizen convention. Keep the title under 50 characters and wrap message at 72 characters. Format as a gitcommit code block.",
    --     context = "git:staged",
    --   },
    -- },

    -- -- default mappings
    -- -- see config/mappings.lua for implementation
    mappings = {
      complete = {
        -- NOTE: CopilotChat画面でCopilotの補完を受けたいので、Tabマッピングをずらす
        -- insert = "<Tab>",
        insert = "<C-k>",
      },
      --   close = {
      --     normal = "q",
      --     insert = "<C-c>",
      --   },
      --   reset = {
      --     normal = "<C-l>",
      --     insert = "<C-l>",
      --   },
      submit_prompt = {
        normal = "<CR>",
        -- insert = "<S-CR>", -- Shift+Enter
        insert = "<CR>",
        -- insert = "<C-s>",
        -- insert = "<C-j>",
        -- insert = "<C-m>",
        -- insert = "<C-]>",
      },
      --   toggle_sticky = {
      --     normal = "grr",
      --   },
      --   clear_stickies = {
      --     normal = "grx",
      --   },
      --   accept_diff = {
      --     normal = "<C-y>",
      --     insert = "<C-y>",
      --   },
      --   jump_to_diff = {
      --     normal = "gj",
      --   },
      --   quickfix_answers = {
      --     normal = "gqa",
      --   },
      --   quickfix_diffs = {
      --     normal = "gqd",
      --   },
      --   yank_diff = {
      --     normal = "gy",
      --     register = '"', -- Default register to use for yanking
      --   },
      --   show_diff = {
      --     normal = "gd",
      --     full_diff = false, -- Show full diff instead of unified diff when showing diff window
      --   },
      --   show_info = {
      --     normal = "gi",
      --   },
      --   show_context = {
      --     normal = "gc",
      --   },
      --   show_help = {
      --     normal = "gh",
      --   },
    },
  })
  -- -- auto_insert_mode = false の代わり。チャットウィンドウに入った時だけ insert に入る。
  -- -- 応答生成中はバッファが modifiable=false になる(Chat:start)ので、その間は入らない。
  -- vim.api.nvim_create_autocmd("BufEnter", {
  --   group = vim.api.nvim_create_augroup("copilot_chat_auto_insert", { clear = true }),
  --   pattern = "copilot-chat", -- バッファ名(nvim_buf_set_name で 'copilot-chat')
  --   callback = function(ev)
  --     vim.schedule(function()
  --       if vim.api.nvim_get_current_buf() ~= ev.buf then
  --         return
  --       end
  --       if not vim.bo[ev.buf].modifiable then
  --         return
  --       end
  --       vim.cmd("startinsert")
  --     end)
  --   end,
  -- })
  -- vim.api.nvim_create_autocmd("FileType", {
  --   pattern = "copilot-chat",
  --   callback = function()
  --     vim.keymap.set("i", "<C-j>", function()
  --       local keys = vim.api.nvim_replace_termcodes("<C-s>", true, false, true)
  --       vim.api.nvim_feedkeys(keys, "i", false)
  --     end, { buffer = true })
  --   end,
  -- })
end
