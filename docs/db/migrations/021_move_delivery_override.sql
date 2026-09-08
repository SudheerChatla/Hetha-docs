-- Migration 021: Move-delivery override kind
-- Purpose: Add a single-action "move a delivery from date A to date B" on top
--          of the existing delivery_day_overrides table (migration 020).
--
--          The original 'swap' kind changes which area's cadence a
--          subscription follows *on one date*. That needs two rows to express
--          a relocation (remove from A, add on B). This migration adds a
--          'move' kind that captures the whole relocation in ONE row:
--            - on from_date  -> the subscription is removed (skipped)
--            - on to_date    -> the subscription is force-added (an order is
--                               generated regardless of its normal cadence)
--
-- Run in: Supabase SQL Editor
--
-- Backward compatible: existing rows default to override_kind='swap' and keep
-- working exactly as before. from_date/to_date are only used for 'move'.

ALTER TABLE public.delivery_day_overrides
  ADD COLUMN override_kind text NOT NULL DEFAULT 'swap'
    CHECK (override_kind IN ('swap', 'move')),
  ADD COLUMN from_date date,
  ADD COLUMN to_date date;

-- A 'move' must have both from_date and to_date, and they must differ.
-- A 'swap' must not carry move dates (it uses override_date instead).
ALTER TABLE public.delivery_day_overrides
  ADD CONSTRAINT delivery_day_overrides_move_dates_check
  CHECK (
    (override_kind = 'move'
       AND from_date IS NOT NULL
       AND to_date   IS NOT NULL
       AND from_date <> to_date)
    OR
    (override_kind = 'swap'
       AND from_date IS NULL
       AND to_date   IS NULL)
  );

-- Index the move dates so the run-sheet generator can look up quickly whether
-- a given target date is a from_date (remove) or a to_date (force-add).
CREATE INDEX idx_delivery_day_overrides_from_date ON public.delivery_day_overrides (from_date)
  WHERE from_date IS NOT NULL;
CREATE INDEX idx_delivery_day_overrides_to_date ON public.delivery_day_overrides (to_date)
  WHERE to_date IS NOT NULL;

-- NOTE on override_date for 'move' rows: override_date is NOT NULL on the base
-- table. For a 'move' we simply set override_date = from_date so the column
-- stays populated and existing per-date lookups (e.g. the "overrides active on
-- this date" badge) still find the row on its from_date. The generator uses
-- from_date/to_date explicitly for the move semantics.
