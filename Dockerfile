FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir boto3==1.43.111
COPY pipeline.py worker.py ./
COPY data/ data/
ENTRYPOINT ["python","-u","worker.py"]
