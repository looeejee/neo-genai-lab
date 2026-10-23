# Local Neo4j and GenAI Plugin Lab

This guide describes a local Kubernetes setup for testing Neo4j’s GenAI Plugin
with Ollama and a Movie dataset.

> **Important:** The commands in the  setup install three separate Helm
> releases. Review `neo-docker.yaml` for the chart’s cluster settings. 

## Prerequisites

- Docker Desktop with Kubernetes enabled
- Docker CLI, `kubectl`, and Helm
- This repository cloned locally
- `genai.conf`, `neo-docker.yaml`, `ollama.yaml`, `Dockerfile`, and the Movie
  dataset dump file
- A Neo4j image/configuration that includes the GenAI Plugin and supports the
  Cypher functions used below

## 1. Create the namespace and ConfigMap

Add and update the Neo4j Helm repository:

```sh
helm repo add neo4j https://helm.neo4j.com/neo4j
helm repo update
```

Create the namespace and ConfigMap:

```sh
kubectl create namespace neo4j

kubectl create configmap neo-genai-conf \
  --from-file=genai.conf="${PWD}/genai.conf" \
  --namespace neo4j
```

Confirm that `neo-docker.yaml` mounts `neo-genai-conf` into the Neo4j pods and
that Neo4j is configured to read the file. Creating the ConfigMap alone does
not make it available to the pods.

## 2. Deploy Neo4j

The following loop installs three Helm releases:

```sh
for i in 1 2 3; do
  helm install "core-${i}" neo4j/neo4j \
    --namespace neo4j \
    --values "${PWD}/neo-docker.yaml"
done
```

Check the pods:

```sh
kubectl get pods --namespace neo4j
```

The original setup expected pods named `core-1-0`, `core-2-0`, and `core-3-0`.
Pod names depend on the release names; use the names returned
by `kubectl get pods`.

## 3. Optional: Build and import a custom image

Use this section only if the Helm `values.yaml` is configured to use a custom image.
*Example*

```
image:
  customImage: neo-genai-test:dev
  imagePullPolicy: Never
```

Ensure that the image tag is correctly added to the Helm values and matches the image built.

Build the Docker image
```sh
docker buildx build --load -t neo-genai-test:dev .
```
Export the image to an archive
```
docker save -o neo-genai-test.tar neo-genai-test:dev
```

Copy the image archive `neo-genai-test.tar` into the Docker Desktop Kubernetes control-plane
container. Replace `desktop-control-plane` if your control-plane container has
a different name:

```sh
docker cp neo-genai-test.tar \
  desktop-control-plane:/root/neo-genai-test.tar
```

Import and verify the image:

```sh
docker exec desktop-control-plane \
  ctr -n k8s.io images import /root/neo-genai-test.tar

docker exec desktop-control-plane \
  crictl images | grep neo-genai-test
```

Rebuild and re-import the image after changing files copied into it.

## 4. Deploy Ollama and download models

Apply the Ollama deployment and wait for it to become ready:

```sh
kubectl apply -f ollama.yaml
kubectl rollout status deployment/ollama --namespace neo4j
```

Download the chat and embedding models:

```sh
kubectl exec --namespace neo4j deployment/ollama -- \
  ollama pull qwen2.5:0.5b

kubectl exec --namespace neo4j deployment/ollama -- \
  ollama pull nomic-embed-text
```

Ensure `genai.conf` setting `genai.openai.baseurl` points to Ollama at an address reachable from the Neo4j
pods. Inside Kubernetes, `localhost` refers to the Neo4j pod itself, not the
Ollama pod. Use the Ollama Kubernetes Service name and port configured by
`ollama.yaml`.

The Cypher examples below use the same model names as the pull commands. Check
the exact model tags available in Ollama if you change them.

## 5. Verify the deployments

```sh
kubectl get pods --namespace neo4j
kubectl get services --namespace neo4j
kubectl get configmap neo-genai-conf --namespace neo4j
```

Wait until the Neo4j and Ollama pods are ready. Confirm that the Neo4j pod can
reach the Ollama Service before testing the GenAI functions.

## 6. Load the Movie dataset

The dump file must be compatible with the Neo4j version and deployment mode
used in this lab. The original procedure copies `embedding.dump` to each Neo4j
pod and loads it independently. Do not use that procedure for a cluster unless
you have verified it is the correct restore and seeding process for your
specific cluster configuration.

For a standalone instance, copy the dump file to the target pod:

```sh
kubectl cp "${PWD}/embedding.dump" \
  neo4j/<neo4j-pod>:/var/lib/neo4j/neo4j.dump
```

Replace `<neo4j-pod>` with a pod name from `kubectl get pods -n neo4j` (in our example: `core-1-0`) Then
follow the Neo4j database-load procedure for the exact Neo4j version and
deployment mode in use. The database must be in the appropriate state for the
load operation.

After loading

## 7. Connect to Neo4j Browser

If the chart exposes Neo4j Browser on the local machine, open:

```text
http://localhost:7474
```

The actual address depends on the Kubernetes Service and port-forwarding
configuration (in our docker-desktop lab we can use localhost). 
If needed, forward the Browser port from the appropriate pod or Service:

```sh
kubectl port-forward --namespace neo4j service/<neo4j-service> 7474:7474
```

Replace `<neo4j-service>` with the Service name returned by
`kubectl get services -n neo4j`.

## 8. Generate and store movie embeddings

This query embeds each movie’s title and plot and stores the resulting vector on
the corresponding `Movie` node. It assumes the GenAI Plugin is installed,
configured, and able to reach Ollama through the provider configuration.

```cypher
CYPHER 25
MATCH (m:Movie)
WHERE m.plot IS NOT NULL
WITH collect(m) AS movies
WITH movies, [movie IN movies | movie.title + ': ' + movie.plot] AS batch
CALL ai.text.embedBatch(
  batch,
  'openai',
  {
    token: 'ollama',
    model: 'nomic-embed-text'
  }
)
YIELD index, vector
WITH movies[index] AS movie, vector
SET movie.embedding = vector;
```

This stores embeddings but does not create a vector index or run a similarity
search. Confirm that the procedure signature and provider configuration match
the GenAI Plugin version installed in the database.

## 9. Test LLM chat

This example sends up to 100 highly rated movie titles and plots directly to
the LLM:

```cypher
CYPHER 25
MATCH (m:Movie)
WHERE m.imdbRating IS NOT NULL
  AND m.plot IS NOT NULL
WITH m
ORDER BY m.imdbRating DESC
LIMIT 100
WITH collect(m.title + ': ' + m.plot) AS movieTexts,
     {
       token: 'ollama',
       model: 'qwen2.5:0.5b',
       vendorOptions: {
         instructions: 'Be short.'
       }
     } AS config
RETURN ai.text.chat(
  'Here is a list of movies with their titles and plots. ' +
  'I like space documentaries. Any recommendations?\n\n' +
  reduce(text = '', item IN movieTexts | text + item + '\n'),
  null,
  'openai',
  config
) AS result;
```

Use the chat ID returned by the installed plugin as the `$chatId` parameter in
a follow-up query:

```cypher
CYPHER 25
WITH {
  token: 'ollama',
  model: 'qwen2.5:0.5b',
  vendorOptions: {
    instructions: 'Be short.'
  }
} AS config
RETURN ai.text.chat(
  'Could you suggest something more animal-oriented?',
  $chatId,
  'openai',
  config
) AS result;
```

Pass the chat ID in the format expected by the installed plugin version and
your Cypher client.

## 10. GraphRAG scope

The embedding and chat examples above are useful for testing the plugin, but
they do not yet demonstrate extensively an advanced configuration for GraphRAG. 

The chat example passes a manually collected list of movie plots directly to the LLM. It does not retrieve
relevant movies using the stored embeddings or add related graph context.

To make this a GraphRAG example, the following steps could be explored:

1. Create a vector index for the movie embeddings, using syntax supported by
   the Neo4j version in this deployment.
2. Embed a user question.
3. Search the vector index for relevant Movie nodes.
4. Retrieve any useful connected graph data.
5. Send the retrieved context to `ai.text.chat()`.

## Troubleshooting

- Check pod status and logs:

  ```sh
  kubectl get pods --namespace neo4j
  kubectl logs --namespace neo4j <pod-name>
  ```

- Check that the ConfigMap exists and is mounted in the Neo4j pod.
- Check that the GenAI Plugin is installed and that its configuration points to
  the Ollama Service, not `localhost`.
- Check that the Ollama models are present:

  ```sh
  kubectl exec --namespace neo4j deployment/ollama -- ollama list
  ```

- Confirm that the model names in the Cypher queries exactly match the tags
  available in Ollama.
- When restoring a dump, use the procedure and command options appropriate to
  the Neo4j version and deployment mode.
