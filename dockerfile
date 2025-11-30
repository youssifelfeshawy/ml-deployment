FROM ubuntu:22.04

# Install dependencies: Java, build tools, git, tcpdump, curl for cert download, libarchive-tools for bsdtar, and Python/ML deps
RUN apt-get update && apt-get install -y \
    openjdk-8-jdk \
    gradle \
    maven \
    git \
    tcpdump \
    libpcap-dev \
    libpcap0.8 \
    curl \
    ca-certificates \
    libarchive-tools \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --install /usr/bin/java java /usr/lib/jvm/java-8-openjdk-amd64/jre/bin/java 1 \
    && update-alternatives --install /usr/bin/javac javac /usr/lib/jvm/java-8-openjdk-amd64/bin/javac 1 \
    && update-alternatives --set java /usr/lib/jvm/java-8-openjdk-amd64/jre/bin/java \
    && update-alternatives --set javac /usr/lib/jvm/java-8-openjdk-amd64/bin/javac \
    && python3 -m pip install --no-cache-dir pandas numpy scikit-learn joblib

ENV JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64
ENV PATH=$JAVA_HOME/bin:$PATH

# Import Let's Encrypt root cert to fix TLS issues with Maven Central
RUN curl -k -o /tmp/isrgrootx1.pem https://letsencrypt.org/certs/isrgrootx1.pem && \
    keytool -trustcacerts -keystore $JAVA_HOME/jre/lib/security/cacerts -storepass changeit -noprompt -importcert -alias isrgrootx1 -file /tmp/isrgrootx1.pem && \
    rm /tmp/isrgrootx1.pem

# Clone the original repo
RUN git clone https://github.com/ahlashkari/CICFlowMeter /cicflowmeter

WORKDIR /cicflowmeter

# Make gradlew executable
RUN chmod +x gradlew

# Install jnetpcap library for Linux with matching version
RUN cd jnetpcap/linux/jnetpcap-1.4.r1425 && \
    mvn install:install-file -Dfile=jnetpcap.jar -DgroupId=org.jnetpcap -DartifactId=jnetpcap -Dversion=1.4.1 -Dpackaging=jar

# Build and package the tool
RUN ./gradlew distZip

# Extract the distribution to /opt/cic for the cfm CLI (using bsdtar to handle quirky ZIP)
RUN mkdir -p /opt/cic && \
    bsdtar -xf build/distributions/CICFlowMeter-4.0.zip -C /opt/cic/

# Copy native lib to the tool's lib dir and patch cfm script to set java.library.path
RUN cp /cicflowmeter/jnetpcap/linux/jnetpcap-1.4.r1425/libjnetpcap.so /opt/cic/CICFlowMeter-4.0/lib/ && \
    sed -i 's/-classpath/-Djava.library.path="$APP_HOME\/lib" -classpath/' /opt/cic/CICFlowMeter-4.0/bin/cfm && \
    chmod +x /opt/cic/CICFlowMeter-4.0/bin/cfm

# Copy ML models and Python script
RUN mkdir -p /opt/ml
COPY minmax_scaler.pkl rf_binary_model.pkl rf_multi_model.pkl label_encoder.pkl feature_columns.pkl dropped_correlated_columns.pkl deploy.py /opt/ml/

# Create entrypoint script for the loop (run Python monitoring in background, then capture loop)
RUN echo '#!/bin/bash\n\
python3 /opt/ml/deploy.py &\n\
mkdir -p /tmp/captures\n\
while true; do\n\
  timestamp=$(date +%Y%m%d_%H%M%S)\n\
  pcap="/tmp/${timestamp}.pcap"\n\
  tcpdump -i any -s 0 -w "$pcap" -G 30 -W 1 2>/dev/null\n\
  /opt/cic/CICFlowMeter-4.0/bin/cfm "$pcap" /tmp/captures\n\
  rm "$pcap"\n\
done' > /entrypoint.sh && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
