-- init.sql — PostgreSQL initialization for home-server
--
-- This script runs once when the PostgreSQL container is first created.
-- It enables the pgvector extension and sets up schemas for the various
-- agent workflows.

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------

-- Enable pgvector for semantic/vector similarity search
CREATE EXTENSION IF NOT EXISTS vector;

-- ---------------------------------------------------------------------------
-- Brain schema — document indexing and semantic search
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS brain;

-- Indexed document chunks with embeddings for semantic search.
-- Used by the "second brain" workflow to index files and search by meaning.
CREATE TABLE IF NOT EXISTS brain.documents (
    id           SERIAL PRIMARY KEY,
    source_path  TEXT NOT NULL,
    chunk_index  INTEGER NOT NULL,
    content      TEXT NOT NULL,
    embedding    vector(1536),           -- OpenAI/Claude embedding dimensions
    metadata     JSONB DEFAULT '{}',
    indexed_at   TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    UNIQUE(source_path, chunk_index)
);

-- IVFFlat index for approximate nearest-neighbor vector search.
-- The 'lists' parameter should be approximately sqrt(number_of_rows).
-- Start with 100; tune upward as the table grows beyond 1M rows.
CREATE INDEX IF NOT EXISTS idx_documents_embedding
    ON brain.documents
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);

-- ---------------------------------------------------------------------------
-- Watchdog schema — financial monitoring and transaction tracking
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS watchdog;

-- Generic table for monitored financial data imported from various sources.
CREATE TABLE IF NOT EXISTS watchdog.transactions (
    id               SERIAL PRIMARY KEY,
    source           TEXT NOT NULL,          -- e.g., 'plaid', 'csv_import'
    transaction_date DATE,
    description      TEXT,
    amount           NUMERIC(12,2),
    category         TEXT,
    metadata         JSONB DEFAULT '{}',
    imported_at      TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Digest schema — content curation and daily digest
-- ---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS digest;

-- Content sources (RSS feeds, newsletters, APIs, etc.)
CREATE TABLE IF NOT EXISTS digest.sources (
    id          SERIAL PRIMARY KEY,
    name        TEXT NOT NULL,
    url         TEXT,
    source_type TEXT NOT NULL,   -- e.g., 'rss', 'api', 'email'
    config      JSONB DEFAULT '{}',
    active      BOOLEAN DEFAULT true
);

-- Individual content items fetched from sources
CREATE TABLE IF NOT EXISTS digest.items (
    id                  SERIAL PRIMARY KEY,
    source_id           INTEGER REFERENCES digest.sources(id),
    title               TEXT,
    content             TEXT,
    summary             TEXT,
    relevance_score     NUMERIC(3,2),
    fetched_at          TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    included_in_digest  BOOLEAN DEFAULT false
);
