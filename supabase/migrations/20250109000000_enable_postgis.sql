-- Enable PostGIS extension for spatial/location functionality
-- Required for GEOMETRY types used in location-based matching

CREATE EXTENSION IF NOT EXISTS postgis;
