# vultr instance create \
#   --region atl \
#   --plan vc2-1c-2gb \
#   --os 2284 \
#   --label "oc-test-1" \
#   --ssh-keys "989d8d33-456b-459c-aab9-7a50a9478088,4040a257-1e0e-4dbe-a9b8-737da98ce0ab" \
#   --script-id "a6f34e43-daac-4cb0-94e9-b41a607fd579"

# vultr instance create \
#   --region atl \
#   --plan vc2-1c-2gb \
#   --snapshot "f456d968-c152-4320-814c-6763164ec9a1" \
#   --label "oc-test-2" \
#   --ssh-keys "989d8d33-456b-459c-aab9-7a50a9478088,4040a257-1e0e-4dbe-a9b8-737da98ce0ab"


# vultr instance create \
#   --region atl \
#   --plan vc2-1c-2gb \
#   --snapshot "bac841a2-d1b3-4450-9d15-fa52616c00ce" \
#   --label "oc-prod-1" \
#   --ssh-keys "a4b8f6d9-fa2e-48a4-b12d-b6162d065e52"

#. 9c0c3b2b-2f3e-4ee4-a578-5e5998f23a3a

# vultr instance create \
#   --region atl \
#   --plan vc2-1c-2gb \
#   --snapshot "9c0c3b2b-2f3e-4ee4-a578-5e5998f23a3a" \
#   --label "oc-prod-01" \
#   --ssh-keys "a4b8f6d9-fa2e-48a4-b12d-b6162d065e52" \
#   --userdata "00577bd8-e47f-4e19-a7a9-dd1e54ba0c9c"

## 
# vultr instance create \
#   --region atl \
#   --plan vc2-1c-2gb \
#   --snapshot "a267c8fc-e198-4aca-b41d-57634e839a52" \
#   --label "oc-prod-01" \
#   --ssh-keys "a4b8f6d9-fa2e-48a4-b12d-b6162d065e52" \

# Instances are created with --count to distribute models across them.
# Models are assigned round-robin across instances (32 models / 10 instances = ~3-4 each).
# The script exits immediately after launching; instances run autonomously and self-destruct.


# uv run orchestrate_vultr.py --count 10 --models anthropic/claude-sonnet-4.6 openai/gpt-5.4

uv run orchestrate_vultr.py --count 10 \
  --models \
  anthropic/claude-haiku-4.5 \
  anthropic/claude-opus-4.5 \
  anthropic/claude-opus-4.6 \
  anthropic/claude-sonnet-4 \
  anthropic/claude-sonnet-4.5 \
  arcee-ai/trinity-large-preview:free \
  deepseek/deepseek-chat \
  deepseek/deepseek-v3.2 \
  google/gemini-1.5-pro \
  google/gemini-2.0-flash \
  google/gemini-2.5-flash \
  google/gemini-2.5-flash-lite \
  google/gemini-3-flash-preview \
  google/gemini-3-pro-preview \
  meta-llama/llama-3.1-70b \
  minimax/minimax-m2.1 \
  minimax/minimax-m2.5 \
  mistral/mistral-large \
  mistralai/devstral-2512 \
  moonshotai/kimi-k2.5 \
  openai/gpt-4o \
  openai/gpt-4o-mini \
  openai/gpt-5-nano \
  openrouter/aurora-alpha \
  qwen/qwen-2.5-72b \
  qwen/qwen3-coder-next \
  qwen/qwen3-max-thinking \
  sourceful/riverflow-v2-pro \
  stepfun/step-3.5-flash \
  x-ai/grok-4.1-fast \
  z-ai/glm-4.5-air \
  z-ai/glm-5

