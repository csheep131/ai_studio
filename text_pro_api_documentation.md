# Text Pro API Documentation

## Overview

Your text_pro stack provides a fully functional OpenAI-compatible API through llama.cpp's `llama-server`. The API is available on two ports:

1. **Port 8081** - Main service port (web UI + API)
2. **Port 11436** - Tunneled API port (API only)

## API Endpoints

### Base URLs
- `http://127.0.0.1:8081/v1/` (when accessing locally through web UI)
- `http://127.0.0.1:11436/v1/` (through SSH tunnel)

### Available Endpoints

#### 1. List Models
```bash
curl -H "Accept: application/json" http://127.0.0.1:8081/v1/models
```

Response:
```json
{
  "models": [
    {
      "name": "Q4_K-GGUF-00001-of-00008.gguf",
      "model": "Q4_K-GGUF-00001-of-00008.gguf",
      "modified_at": "",
      "size": "",
      "digest": "",
      "type": "model",
      "description": "",
      "tags": [""],
      "capabilities": ["completion"],
      "parameters": "",
      "details": {
        "parent_model": "",
        "format": "gguf",
        "family": "",
        "families": [""],
        "parameter_size": "",
        "quantization_level": ""
      }
    }
  ],
  "object": "list",
  "data": [
    {
      "id": "Q4_K-GGUF-00001-of-00008.gguf",
      "aliases": [],
      "tags": [],
      "object": "model",
      "created": 1774610831,
      "owned_by": "llamacpp",
      "meta": {
        "vocab_type": 2,
        "n_vocab": 248320,
        "n_ctx_train": 262144,
        "n_embd": 3072,
        "n_params": 122111526912,
        "size": 74197241856
      }
    }
  ]
}
```

#### 2. Chat Completions
```bash
curl -X POST http://127.0.0.1:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{
    "model": "Q4_K-GGUF-00001-of-00008.gguf",
    "messages": [
      {"role": "user", "content": "Hello, how are you?"}
    ],
    "stream": false,
    "temperature": 0.7,
    "max_tokens": 1000
  }'
```

#### 3. Health Check
```bash
curl -H "Accept: application/json" http://127.0.0.1:8081/health
```

#### 4. Completions (Legacy endpoint)
```bash
curl -X POST http://127.0.0.1:8081/v1/completions \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{
    "model": "Q4_K-GGUF-00001-of-00008.gguf",
    "prompt": "Once upon a time",
    "max_tokens": 100
  }'
```

## Python Client Examples

### Using OpenAI Python Library
```python
import openai

# Configure the client
client = openai.OpenAI(
    base_url="http://127.0.0.1:8081/v1",
    api_key="not-needed"  # llama.cpp doesn't require API key
)

# List available models
models = client.models.list()
print("Available models:", [model.id for model in models.data])

# Chat completion
response = client.chat.completions.create(
    model="Q4_K-GGUF-00001-of-00008.gguf",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Explain quantum computing in simple terms."}
    ],
    temperature=0.7,
    max_tokens=500
)

print("Response:", response.choices[0].message.content)
```

### Using requests library
```python
import requests
import json

BASE_URL = "http://127.0.0.1:8081/v1"

def list_models():
    response = requests.get(f"{BASE_URL}/models", headers={"Accept": "application/json"})
    return response.json()

def chat_completion(messages, model="Q4_K-GGUF-00001-of-00008.gguf", stream=False):
    payload = {
        "model": model,
        "messages": messages,
        "stream": stream,
        "temperature": 0.7,
        "max_tokens": 1000
    }
    
    response = requests.post(
        f"{BASE_URL}/chat/completions",
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        json=payload
    )
    
    return response.json()

# Example usage
if __name__ == "__main__":
    # List models
    models = list_models()
    print("Models:", json.dumps(models, indent=2))
    
    # Chat example
    messages = [
        {"role": "user", "content": "What is the capital of France?"}
    ]
    
    response = chat_completion(messages)
    print("\nChat response:", response["choices"][0]["message"]["content"])
```

## Stream Responses

For streaming responses, set `"stream": true`:

```python
import requests
import json

def stream_chat_completion(messages):
    payload = {
        "model": "Q4_K-GGUF-00001-of-00008.gguf",
        "messages": messages,
        "stream": True,
        "temperature": 0.7
    }
    
    response = requests.post(
        "http://127.0.0.1:8081/v1/chat/completions",
        headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
        json=payload,
        stream=True
    )
    
    for line in response.iter_lines():
        if line:
            line = line.decode('utf-8')
            if line.startswith('data: '):
                data = line[6:]  # Remove 'data: ' prefix
                if data != '[DONE]':
                    try:
                        chunk = json.loads(data)
                        if 'choices' in chunk and chunk['choices']:
                            delta = chunk['choices'][0].get('delta', {})
                            if 'content' in delta:
                                print(delta['content'], end='', flush=True)
                    except json.JSONDecodeError:
                        pass

# Usage
messages = [{"role": "user", "content": "Tell me a story about a dragon"}]
stream_chat_completion(messages)
```

## Command Line Examples

### Simple chat
```bash
curl -X POST http://127.0.0.1:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Q4_K-GGUF-00001-of-00008.gguf",
    "messages": [
      {"role": "user", "content": "What is the meaning of life?"}
    ],
    "temperature": 0.7
  }' | jq '.choices[0].message.content'
```

### With jq for pretty output
```bash
curl -s -X POST http://127.0.0.1:8081/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Q4_K-GGUF-00001-of-00008.gguf",
    "messages": [
      {"role": "user", "content": "Write a haiku about programming"}
    ]
  }' | jq -r '.choices[0].message.content'
```

## Model Information

The current model is a **122B parameter Qwen3.5 MoE model** quantized to Q4_K_M GGUF format:
- **Model name**: `Q4_K-GGUF-00001-of-00008.gguf`
- **Total parameters**: 122.1 billion
- **Context size**: 262,144 tokens
- **Vocabulary size**: 248,320
- **Embedding dimension**: 3,072
- **Model size**: ~74.2 GB (quantized)

## Troubleshooting

### Common Issues

1. **"gzip is not supported by this browser"**
   - This appears when accessing the root endpoint `/` without proper headers
   - Solution: Use API endpoints (`/v1/...`) with `Accept: application/json` header

2. **404 Not Found**
   - Ensure llama-server is running: Check with `curl http://127.0.0.1:8081/v1/models`
   - Restart the stack: `./studio.sh restart text_pro`

3. **Connection refused**
   - The SSH tunnel might not be active
   - Start tunnel: `./studio.sh tunnel text_pro`
   - Or check status: `./studio.sh status text_pro`

4. **Slow responses**
   - The 122B model requires significant compute
   - Consider using the regular "text" stack for smaller, faster models
   - Adjust `max_tokens` to limit response length

## Advanced Configuration

### Custom API Client Script

Create `text_pro_api_client.py`:

```python
#!/usr/bin/env python3
"""
Text Pro API Client
Usage: python text_pro_api_client.py "Your prompt here"
"""

import sys
import requests
import json

class TextProClient:
    def __init__(self, base_url="http://127.0.0.1:8081/v1"):
        self.base_url = base_url
        self.model = "Q4_K-GGUF-00001-of-00008.gguf"
    
    def chat(self, prompt, system_message=None, temperature=0.7, max_tokens=1000):
        messages = []
        
        if system_message:
            messages.append({"role": "system", "content": system_message})
        
        messages.append({"role": "user", "content": prompt})
        
        payload = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "stream": False
        }
        
        response = requests.post(
            f"{self.base_url}/chat/completions",
            headers={"Content-Type": "application/json"},
            json=payload
        )
        
        if response.status_code == 200:
            return response.json()["choices"][0]["message"]["content"]
        else:
            raise Exception(f"API error: {response.status_code} - {response.text}")
    
    def stream_chat(self, prompt, system_message=None, temperature=0.7):
        messages = []
        
        if system_message:
            messages.append({"role": "system", "content": system_message})
        
        messages.append({"role": "user", "content": prompt})
        
        payload = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "stream": True
        }
        
        response = requests.post(
            f"{self.base_url}/chat/completions",
            headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
            json=payload,
            stream=True
        )
        
        for line in response.iter_lines():
            if line:
                line = line.decode('utf-8')
                if line.startswith('data: '):
                    data = line[6:]
                    if data != '[DONE]':
                        try:
                            chunk = json.loads(data)
                            if 'choices' in chunk and chunk['choices']:
                                delta = chunk['choices'][0].get('delta', {})
                                if 'content' in delta:
                                    yield delta['content']
                        except json.JSONDecodeError:
                            pass

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python text_pro_api_client.py \"Your prompt here\"")
        sys.exit(1)
    
    client = TextProClient()
    prompt = sys.argv[1]
    
    print(f"Prompt: {prompt}")
    print("\n" + "="*50 + "\n")
    
    # Non-streaming response
    response = client.chat(prompt)
    print(f"Response: {response}")
    
    # Or for streaming:
    # print("Streaming response:")
    # for chunk in client.stream_chat(prompt):
    #     print(chunk, end='', flush=True)
    # print()
```

## Integration Examples

### With LangChain
```python
from langchain_openai import ChatOpenAI
from langchain.schema import HumanMessage

llm = ChatOpenAI(
    openai_api_base="http://127.0.0.1:8081/v1",
    openai_api_key="not-needed",
    model_name="Q4_K-GGUF-00001-of-00008.gguf",
    temperature=0.7,
    max_tokens=1000
)

response = llm([HumanMessage(content="Explain blockchain technology")])
print(response.content)
```

### With OpenAI SDK
```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:11436/v1",  # Using tunnel port
    api_key="not-needed"
)

completion = client.chat.completions.create(
    model="Q4_K-GGUF-00001-of-00008.gguf",
    messages=[
        {"role": "user", "content": "Write Python code to calculate fibonacci sequence"}
    ]
)

print(completion.choices[0].message.content)
```

## Monitoring

Check API status:
```bash
# Check if API is responding
curl -s http://127.0.0.1:8081/v1/models > /dev/null && echo "API is up" || echo "API is down"

# Check response time
time curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8081/v1/models
```

## Notes

- The API is fully compatible with OpenAI's API specification
- No authentication required (running locally)
- Supports both streaming and non-streaming responses
- The model is a large 122B parameter model - responses may take time
- For production use, consider adding rate limiting and authentication
- The web UI on port 8081 provides a convenient interface for testing