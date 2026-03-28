# Text Pro API Interface

## ✅ Problem Solved

You mentioned: "text pro hab ich nur eine webui kein api interface das hätte ich gerne auch mit llama.cpp"

**GOOD NEWS:** You actually DO have a fully functional API interface! The issue was just that it wasn't properly documented/exposed.

## 🚀 What's Available Now

### 1. **Web UI** (Port 8081)
- Access via: `http://127.0.0.1:8081/`
- Provides a graphical interface for chatting with the model

### 2. **API Interface** (Ports 8081 & 11436)
- **Port 8081**: `http://127.0.0.1:8081/v1/` (local access)
- **Port 11436**: `http://127.0.0.1:11436/v1/` (SSH tunnel access)
- **Fully OpenAI-compatible API** powered by llama.cpp

## 📋 Quick Start Examples

### Test API Health
```bash
python3 text_pro_api_client.py --health
```

### List Available Models
```bash
python3 text_pro_api_client.py --models
```

### Simple Chat
```bash
python3 text_pro_api_client.py "What is AI?"
```

### Stream Response
```bash
python3 text_pro_api_client.py --stream "Tell me a story"
```

### Using curl
```bash
# List models
curl -H "Accept: application/json" http://127.0.0.1:8081/v1/models

# Chat completion
curl -X POST http://127.0.0.1:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Q4_K-GGUF-00001-of-00008.gguf",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

## 📁 Files Created

1. **`text_pro_api_documentation.md`** - Complete API documentation
2. **`text_pro_api_client.py`** - Python client with CLI interface
3. **`API_README.md`** - This quick start guide

## 🔧 Technical Details

### Model Information
- **Name**: `Q4_K-GGUF-00001-of-00008.gguf`
- **Size**: 122B parameters (Qwen3.5 MoE)
- **Quantization**: Q4_K_M GGUF
- **Context**: 262,144 tokens

### API Compatibility
- ✅ OpenAI API v1 compatible
- ✅ Supports streaming (`stream: true`)
- ✅ No authentication required (local only)
- ✅ Works with OpenAI SDK, LangChain, etc.

## 🐛 Common Issues & Solutions

### "gzip is not supported by this browser"
- **Cause**: Accessing root endpoint `/` without proper headers
- **Solution**: Use API endpoints (`/v1/...`) with `Accept: application/json`

### Connection refused
```bash
# Start the stack
./studio.sh start text_pro

# Start tunnel
./studio.sh tunnel text_pro

# Check status
./studio.sh status text_pro
```

### Slow responses
- The 122B model is computationally intensive
- Reduce `max_tokens` parameter
- Use streaming for better UX

## 🎯 Integration Examples

### With OpenAI Python SDK
```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8081/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="Q4_K-GGUF-00001-of-00008.gguf",
    messages=[{"role": "user", "content": "Hello"}]
)
```

### With LangChain
```python
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(
    openai_api_base="http://127.0.0.1:8081/v1",
    openai_api_key="not-needed",
    model_name="Q4_K-GGUF-00001-of-00008.gguf"
)
```

## 📊 Monitoring

```bash
# Quick health check
curl -s http://127.0.0.1:8081/v1/models > /dev/null && echo "✅ API OK" || echo "❌ API Down"

# Response time
time curl -s -o /dev/null http://127.0.0.1:8081/v1/models
```

## 🎉 Summary

**Your text_pro stack now has:**
1. ✅ Web UI on port 8081
2. ✅ Full API interface on port 8081 (`/v1/...`)
3. ✅ Tunneled API on port 11436
4. ✅ Python client with CLI
5. ✅ Complete documentation
6. ✅ OpenAI compatibility

The API was already working - it just needed proper documentation and client tools! 🚀