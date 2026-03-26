FROM public.ecr.aws/lambda/python:3.12

# Amazon Linux 2023にはLibreOfficeパッケージがないため、
# Fedora 39のRPMリポジトリからLibreOfficeをインストールする
RUN dnf install -y \
    poppler-utils \
    && dnf clean all

# LibreOfficeはRPMパッケージを直接ダウンロードしてインストール
# Amazon Linux 2023互換のLibreOffice RPMを取得
RUN dnf install -y \
    tar gzip wget \
    java-17-amazon-corretto-headless \
    cups-libs \
    libXinerama \
    libXrender \
    libX11-xcb \
    libxshmfence \
    mesa-libGL \
    cairo \
    nss \
    nspr \
    at-spi2-core \
    google-noto-sans-cjk-jp-fonts \
    && dnf clean all

# LibreOffice AppImageの代わりに、公式RPMパッケージを使用
RUN cd /tmp && \
    wget -q "https://download.documentfoundation.org/libreoffice/stable/26.2.2/rpm/x86_64/LibreOffice_26.2.2_Linux_x86-64_rpm.tar.gz" && \
    tar xzf LibreOffice_26.2.2_Linux_x86-64_rpm.tar.gz && \
    cd LibreOffice_26.2.2*/RPMS && \
    rpm -ivh --nodeps *.rpm && \
    cd /tmp && \
    rm -rf LibreOffice_* && \
    ln -sf /opt/libreoffice26.2/program/soffice /usr/local/bin/libreoffice

# Python依存パッケージをインストール
COPY requirements.txt ${LAMBDA_TASK_ROOT}/
RUN pip install --no-cache-dir -r ${LAMBDA_TASK_ROOT}/requirements.txt

# ハンドラーコードをコピー
COPY handler.py ${LAMBDA_TASK_ROOT}/

# Lambda ハンドラーを指定
CMD ["handler.lambda_handler"]
