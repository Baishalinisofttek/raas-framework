#!/bin/bash
cd agent
uvicorn raas_agent:app --host 0.0.0.0 --port $PORT
