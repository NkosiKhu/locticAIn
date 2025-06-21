#!/usr/bin/env python3
"""
MCP Stdio Bridge for Rails MCP Server
Bridges between MCP stdio protocol and Rails HTTP MCP server
"""

import sys
import json
import requests
import uuid
from threading import Thread
import time
import logging
from datetime import datetime

# Set up logging to stderr with detailed formatting
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s [BRIDGE] %(levelname)s: %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S',
    stream=sys.stderr
)
logger = logging.getLogger('mcp_bridge')

class McpStdioBridge:
    def __init__(self):
        self.server_url = "http://localhost:3000/mcp"
        self.session_id = str(uuid.uuid4())
        self.headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
            'Mcp-Session-Id': self.session_id,
            'MCP-Protocol-Version': '2025-03-26'
        }
        
        logger.info(f"=== MCP STDIO BRIDGE INITIALIZED ===")
        logger.info(f"Server URL: {self.server_url}")
        logger.info(f"Session ID: {self.session_id}")
        logger.info(f"Headers: {json.dumps(self.headers, indent=2)}")

    def send_request(self, message):
        """Send JSON-RPC request to Rails server and return response"""
        logger.debug(f"--- SENDING REQUEST TO RAILS ---")
        logger.debug(f"URL: {self.server_url}")
        logger.debug(f"Method: {message.get('method', 'unknown')}")
        logger.debug(f"ID: {message.get('id', 'none')}")
        logger.debug(f"Request payload: {json.dumps(message, indent=2)}")
        logger.debug(f"Request headers: {json.dumps(self.headers, indent=2)}")
        
        try:
            start_time = time.time()
            response = requests.post(
                self.server_url,
                json=message,
                headers=self.headers,
                timeout=30
            )
            request_duration = time.time() - start_time
            
            logger.debug(f"--- RECEIVED RESPONSE FROM RAILS ---")
            logger.debug(f"Status: {response.status_code}")
            logger.debug(f"Duration: {request_duration:.3f}s")
            logger.debug(f"Response headers: {dict(response.headers)}")
            
            if response.status_code == 200:
                response_data = response.json()
                logger.debug(f"Response payload: {json.dumps(response_data, indent=2)}")
                logger.info(f"✅ SUCCESS: {message.get('method', 'unknown')} -> {response.status_code}")
                return response_data
            else:
                logger.error(f"❌ HTTP ERROR: {response.status_code}")
                logger.error(f"Response text: {response.text}")
                error_response = {
                    "jsonrpc": "2.0",
                    "error": {
                        "code": -32603,
                        "message": f"HTTP {response.status_code}: {response.text}"
                    },
                    "id": message.get("id")
                }
                logger.debug(f"Generated error response: {json.dumps(error_response, indent=2)}")
                return error_response
                
        except Exception as e:
            logger.error(f"❌ CONNECTION ERROR: {str(e)}")
            logger.error(f"Exception type: {type(e).__name__}")
            error_response = {
                "jsonrpc": "2.0",
                "error": {
                    "code": -32603,
                    "message": f"Connection error: {str(e)}"
                },
                "id": message.get("id")
            }
            logger.debug(f"Generated error response: {json.dumps(error_response, indent=2)}")
            return error_response

    def run(self):
        """Main stdio bridge loop"""
        logger.info("=== STARTING BRIDGE MAIN LOOP ===")
        
        # Send initialization message
        logger.info("--- SENDING INITIALIZATION MESSAGE ---")
        init_message = {
            "jsonrpc": "2.0",
            "method": "initialize",
            "id": 1,
            "params": {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "clientInfo": {
                    "name": "Langflow MCP Bridge",
                    "version": "1.0.0"
                }
            }
        }
        
        init_response = self.send_request(init_message)
        logger.info(f"Initialization response: {json.dumps(init_response, indent=2)}")
        
        logger.info("--- STARTING STDIN MESSAGE PROCESSING ---")
        logger.info("Waiting for messages from Langflow via stdin...")
        
        # Process stdin messages
        message_count = 0
        for line in sys.stdin:
            message_count += 1
            line = line.strip()
            logger.debug(f"=== STDIN MESSAGE #{message_count} ===")
            logger.debug(f"Raw line: {repr(line)}")
            
            if not line:
                logger.debug("Empty line, skipping...")
                continue
                
            try:
                logger.debug("Parsing JSON message...")
                message = json.loads(line)
                logger.info(f"📥 RECEIVED FROM LANGFLOW: {message.get('method', 'response')} (ID: {message.get('id', 'none')})")
                logger.debug(f"Parsed message: {json.dumps(message, indent=2)}")
                
                logger.debug("Forwarding to Rails server...")
                response = self.send_request(message)
                
                logger.info(f"📤 SENDING TO LANGFLOW: Response for {message.get('method', 'unknown')}")
                logger.debug(f"Response to send: {json.dumps(response, indent=2)}")
                
                # Send response back to Langflow via stdout
                print(json.dumps(response), flush=True)
                logger.debug("Response sent to stdout and flushed")
                
            except json.JSONDecodeError as e:
                logger.error(f"❌ JSON PARSE ERROR: {str(e)}")
                logger.error(f"Failed to parse line: {repr(line)}")
                error_response = {
                    "jsonrpc": "2.0",
                    "error": {
                        "code": -32700,
                        "message": "Parse error"
                    },
                    "id": None
                }
                logger.debug(f"Sending parse error response: {json.dumps(error_response)}")
                print(json.dumps(error_response), flush=True)
            except Exception as e:
                logger.error(f"❌ UNEXPECTED ERROR: {str(e)}")
                logger.error(f"Exception type: {type(e).__name__}")
                import traceback
                logger.error(f"Traceback: {traceback.format_exc()}")
        
        logger.info("=== STDIN CLOSED - BRIDGE SHUTTING DOWN ===")

if __name__ == "__main__":
    import os
    
    logger.info("=== MCP STDIO BRIDGE STARTING ===")
    logger.info(f"Python version: {sys.version}")
    logger.info(f"Arguments: {sys.argv}")
    logger.info(f"Hardcoded server URL: http://localhost:3000/mcp")
    
    try:
        bridge = McpStdioBridge()
        bridge.run()
    except KeyboardInterrupt:
        logger.info("=== BRIDGE INTERRUPTED BY USER ===")
    except Exception as e:
        logger.error(f"=== BRIDGE CRASHED: {str(e)} ===")
        import traceback
        logger.error(f"Traceback: {traceback.format_exc()}")
        sys.exit(1) 