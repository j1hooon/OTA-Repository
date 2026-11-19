# OTA FastAPI 서버 베이스 이미지: 의존성만 이미지에 굽고, 앱 코드(main.py)는 ConfigMap 으로 마운트한다.
#  -> 코드 변경은 이미지 재빌드 없이 Ansible(ConfigMap) 배포만으로 반영되고,
#  -> 파드 시작 시 pip install 이 없어 시작이 빠르며 PyPI 장애/DNS 장애와 무관하다(DR 시 특히 중요).
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN pip install \
      fastapi==0.110.0 \
      uvicorn==0.28.0 \
      psycopg2-binary==2.9.9 \
      redis==5.0.3 \
      pydantic==2.6.4 \
      boto3==1.34.84

WORKDIR /app
EXPOSE 80

# exec 형식: uvicorn 이 PID 1 이 되어 SIGTERM 을 직접 받아 즉시 종료(Terminating 지연 방지)
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "80", "--app-dir", "/app"]
