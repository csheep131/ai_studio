#!/usr/bin/env python3
"""
Text Pro API Client
Usage: 
  python text_pro_api_client.py "Your prompt here"
  python text_pro_api_client.py --stream "Your prompt here"
  python text_pro_api_client.py --models
"""

import sys
import argparse
import requests
import json
from typing import Generator, Optional

class TextProClient:
    def __init__(self, base_url: str = "http://127.0.0.1:8081/v1"):
        """
        Initialize the Text Pro API client.
        
        Args:
            base_url: Base URL of the API (default: http://127.0.0.1:8081/v1)
                     Alternative: http://127.0.0.1:11436/v1 for tunnel port
        """
        self.base_url = base_url.rstrip('/')
        self.model = self._get_available_model()
    
    def _get_available_model(self) -> str:
        """Get the first available model from the API."""
        try:
            response = requests.get(
                f"{self.base_url}/models",
                headers={"Accept": "application/json"},
                timeout=10
            )
            if response.status_code == 200:
                data = response.json()
                if data.get('data') and len(data['data']) > 0:
                    return data['data'][0]['id']
                elif data.get('models') and len(data['models']) > 0:
                    return data['models'][0]['name']
        except Exception as e:
            print(f"Warning: Could not fetch model list: {e}")
        
        # Fallback to default model name
        return "Q4_K-GGUF-00001-of-00008.gguf"
    
    def list_models(self) -> dict:
        """List all available models."""
        response = requests.get(
            f"{self.base_url}/models",
            headers={"Accept": "application/json"},
            timeout=10
        )
        response.raise_for_status()
        return response.json()
    
    def chat(
        self, 
        prompt: str, 
        system_message: Optional[str] = None,
        temperature: float = 0.7,
        max_tokens: int = 1000,
        stream: bool = False
    ) -> Generator[str, None, None] or str:
        """
        Send a chat completion request.
        
        Args:
            prompt: User prompt/message
            system_message: Optional system message
            temperature: Creativity temperature (0.0 to 1.0)
            max_tokens: Maximum tokens in response
            stream: Whether to stream the response
            
        Returns:
            If stream=True: Generator yielding response chunks
            If stream=False: Complete response string
        """
        messages = []
        
        if system_message:
            messages.append({"role": "system", "content": system_message})
        
        messages.append({"role": "user", "content": prompt})
        
        payload = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "stream": stream
        }
        
        if stream:
            return self._stream_chat(payload)
        else:
            return self._complete_chat(payload)
    
    def _complete_chat(self, payload: dict) -> str:
        """Non-streaming chat completion."""
        response = requests.post(
            f"{self.base_url}/chat/completions",
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            json=payload,
            timeout=60
        )
        response.raise_for_status()
        data = response.json()
        
        if 'choices' in data and data['choices']:
            return data['choices'][0]['message']['content']
        else:
            raise Exception(f"No choices in response: {data}")
    
    def _stream_chat(self, payload: dict) -> Generator[str, None, None]:
        """Streaming chat completion."""
        response = requests.post(
            f"{self.base_url}/chat/completions",
            headers={"Content-Type": "application/json", "Accept": "text/event-stream"},
            json=payload,
            stream=True,
            timeout=60
        )
        response.raise_for_status()
        
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
                                    yield delta['content']
                        except json.JSONDecodeError:
                            pass
    
    def health_check(self) -> bool:
        """Check if API is healthy."""
        try:
            response = requests.get(
                f"{self.base_url}/models",
                headers={"Accept": "application/json"},
                timeout=5
            )
            return response.status_code == 200
        except:
            return False

def main():
    parser = argparse.ArgumentParser(description="Text Pro API Client")
    parser.add_argument("prompt", nargs="?", help="Prompt to send to the model")
    parser.add_argument("--stream", action="store_true", help="Stream the response")
    parser.add_argument("--models", action="store_true", help="List available models")
    parser.add_argument("--system", type=str, help="System message")
    parser.add_argument("--temperature", type=float, default=0.7, help="Temperature (0.0 to 1.0)")
    parser.add_argument("--max-tokens", type=int, default=1000, help="Maximum tokens in response")
    parser.add_argument("--url", type=str, default="http://127.0.0.1:8081/v1", 
                       help="API URL (default: http://127.0.0.1:8081/v1)")
    parser.add_argument("--health", action="store_true", help="Check API health")
    
    args = parser.parse_args()
    
    client = TextProClient(base_url=args.url)
    
    if args.health:
        if client.health_check():
            print("✅ API is healthy")
        else:
            print("❌ API is not responding")
        return
    
    if args.models:
        try:
            models = client.list_models()
            print("Available models:")
            print(json.dumps(models, indent=2))
        except Exception as e:
            print(f"Error listing models: {e}")
        return
    
    if not args.prompt:
        parser.print_help()
        print("\nExamples:")
        print("  python text_pro_api_client.py \"What is AI?\"")
        print("  python text_pro_api_client.py --stream \"Tell me a story\"")
        print("  python text_pro_api_client.py --models")
        print("  python text_pro_api_client.py --health")
        return
    
    print(f"Model: {client.model}")
    print(f"Prompt: {args.prompt}")
    if args.system:
        print(f"System: {args.system}")
    print("-" * 50)
    
    try:
        if args.stream:
            print("Response (streaming): ", end="", flush=True)
            for chunk in client.chat(
                prompt=args.prompt,
                system_message=args.system,
                temperature=args.temperature,
                max_tokens=args.max_tokens,
                stream=True
            ):
                print(chunk, end="", flush=True)
            print()  # New line after streaming
        else:
            print("Response: ", end="", flush=True)
            response = client.chat(
                prompt=args.prompt,
                system_message=args.system,
                temperature=args.temperature,
                max_tokens=args.max_tokens,
                stream=False
            )
            print(response)
    
    except requests.exceptions.ConnectionError:
        print(f"\n❌ Connection error: Could not connect to {args.url}")
        print("Make sure the text_pro stack is running:")
        print("  ./studio.sh start text_pro")
        print("  ./studio.sh tunnel text_pro")
    except requests.exceptions.Timeout:
        print("\n❌ Request timeout: The model is taking too long to respond")
        print("Try reducing max_tokens or using a simpler prompt")
    except Exception as e:
        print(f"\n❌ Error: {e}")

if __name__ == "__main__":
    main()