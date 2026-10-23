FROM neo4j:2026.10.1-enterprise

COPY genai.conf /config/genai.conf

RUN chmod 440 /config/genai.conf
RUN chown neo4j:neo4j /config/genai.conf

CMD ["neo4j", "start", "--expand-commands"]