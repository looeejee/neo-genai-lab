FROM neo4j:2026.10.1-enterprise

COPY genai.conf /config/genai.conf
RUN mv /var/lib/neo4j/products/neo4j-genai-plugin-*.jar /var/lib/neo4j/plugins/
RUN chmod 440 /config/genai.conf
RUN chown neo4j:neo4j /config/genai.conf

CMD ["neo4j", "start", "--expand-commands"]