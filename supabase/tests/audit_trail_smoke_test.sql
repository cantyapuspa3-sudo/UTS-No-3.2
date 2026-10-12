-- Run only against a disposable Supabase project after applying migration 001.
-- Requires at least one auth user assigned maker and another assigned approver/admin.
-- All test records are rolled back at the end.
BEGIN;

DO $$
DECLARE
    maker_id UUID;
    approver_id UUID;
    original_id BIGINT;
    reversal_id BIGINT;
    journal_result JSONB;
    verification JSONB;
    operation_rejected BOOLEAN;
    test_voucher TEXT := 'TEST-' || replace(gen_random_uuid()::TEXT, '-', '');
BEGIN
    SELECT user_id INTO maker_id
    FROM public.auditguard_user_roles
    WHERE role = 'maker'
    ORDER BY user_id
    LIMIT 1;
    SELECT user_id INTO approver_id
    FROM public.auditguard_user_roles
    WHERE role IN ('approver', 'admin')
    ORDER BY user_id
    LIMIT 1;

    IF maker_id IS NULL OR approver_id IS NULL THEN
        RAISE EXCEPTION 'Test prerequisite: configure maker and approver users first.';
    END IF;

    PERFORM set_config('request.jwt.claim.sub', maker_id::TEXT, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    operation_rejected := FALSE;
    BEGIN
        PERFORM public.auditguard_create_journal(
            test_voucher || '-UNBALANCED',
            CURRENT_DATE,
            'Penerima Uji',
            'Jurnal tidak seimbang',
            '[
                {"account_code":"5-3100","debit":"1500000","credit":"0"},
                {"account_code":"1-1120","debit":"0","credit":"1400000"}
            ]'::JSONB
        );
    EXCEPTION WHEN OTHERS THEN
        operation_rejected := TRUE;
    END;
    IF NOT operation_rejected THEN
        RAISE EXCEPTION 'FAIL: unbalanced journal was accepted.';
    END IF;

    journal_result := public.auditguard_create_journal(
        test_voucher,
        CURRENT_DATE,
        'Penerima Uji',
        'Transaksi pengujian audit trail',
        '[
            {"account_code":"5-3100","description":"Beban uji","debit":"1500000","credit":"0"},
            {"account_code":"1-1120","description":"Kas uji","debit":"0","credit":"1500000"}
        ]'::JSONB
    );
    original_id := (journal_result->>'id')::BIGINT;

    verification := public.auditguard_verify_journal(original_id);
    IF (verification->>'valid')::BOOLEAN IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: checksum should initially be valid.';
    END IF;

    operation_rejected := FALSE;
    BEGIN
        PERFORM public.auditguard_post_journal(original_id);
    EXCEPTION WHEN OTHERS THEN
        operation_rejected := TRUE;
    END;
    IF NOT operation_rejected THEN
        RAISE EXCEPTION 'FAIL: maker was allowed to post a journal.';
    END IF;

    PERFORM set_config('request.jwt.claim.sub', approver_id::TEXT, true);
    PERFORM public.auditguard_post_journal(original_id);

    operation_rejected := FALSE;
    BEGIN
        UPDATE public.auditguard_journal_headers
        SET description = 'Perubahan tidak diizinkan'
        WHERE id = original_id;
    EXCEPTION WHEN OTHERS THEN
        operation_rejected := TRUE;
    END;
    IF NOT operation_rejected THEN
        RAISE EXCEPTION 'FAIL: posted header update was not rejected.';
    END IF;

    operation_rejected := FALSE;
    BEGIN
        DELETE FROM public.auditguard_journal_headers
        WHERE id = original_id;
    EXCEPTION WHEN OTHERS THEN
        operation_rejected := TRUE;
    END;
    IF NOT operation_rejected THEN
        RAISE EXCEPTION 'FAIL: posted header deletion was not rejected.';
    END IF;

    operation_rejected := FALSE;
    BEGIN
        DELETE FROM public.auditguard_journal_lines
        WHERE id = (
            SELECT id FROM public.auditguard_journal_lines
            WHERE journal_id = original_id
            ORDER BY id
            LIMIT 1
        );
    EXCEPTION WHEN OTHERS THEN
        operation_rejected := TRUE;
    END;
    IF NOT operation_rejected THEN
        RAISE EXCEPTION 'FAIL: posted journal line deletion was not rejected.';
    END IF;

    operation_rejected := FALSE;
    BEGIN
        UPDATE public.auditguard_journal_lines
        SET description = 'Perubahan tidak diizinkan'
        WHERE journal_id = original_id;
    EXCEPTION WHEN OTHERS THEN
        operation_rejected := TRUE;
    END;
    IF NOT operation_rejected THEN
        RAISE EXCEPTION 'FAIL: posted journal line update was not rejected.';
    END IF;

    operation_rejected := FALSE;
    BEGIN
        INSERT INTO public.auditguard_journal_lines
            (journal_id, account_code, description, debit, credit)
        VALUES (original_id, '5-3100', 'Baris tambahan tidak diizinkan', 1, 0);
    EXCEPTION WHEN OTHERS THEN
        operation_rejected := TRUE;
    END;
    IF NOT operation_rejected THEN
        RAISE EXCEPTION 'FAIL: posted journal line insertion was not rejected.';
    END IF;

    journal_result := public.auditguard_reverse_journal(
        original_id,
        test_voucher || '-REV',
        CURRENT_DATE
    );
    reversal_id := (journal_result->>'id')::BIGINT;
    IF (journal_result->>'reverses_id')::BIGINT <> original_id
       OR journal_result->>'posting_status' <> 'DRAFT' THEN
        RAISE EXCEPTION 'FAIL: reversing entry linkage or status is incorrect.';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.auditguard_journal_lines AS original_line
        WHERE original_line.journal_id = original_id
          AND NOT EXISTS (
              SELECT 1
              FROM public.auditguard_journal_lines AS reversal_line
              WHERE reversal_line.journal_id = reversal_id
                AND reversal_line.account_code = original_line.account_code
                AND reversal_line.debit = original_line.credit
                AND reversal_line.credit = original_line.debit
          )
    ) THEN
        RAISE EXCEPTION 'FAIL: reversing entry did not swap debit/credit.';
    END IF;

    operation_rejected := FALSE;
    BEGIN
        PERFORM public.auditguard_reverse_journal(
            original_id,
            test_voucher || '-REV2',
            CURRENT_DATE
        );
    EXCEPTION WHEN OTHERS THEN
        operation_rejected := TRUE;
    END;
    IF NOT operation_rejected THEN
        RAISE EXCEPTION 'FAIL: duplicate reversing entry was accepted.';
    END IF;

    UPDATE public.auditguard_journal_lines
    SET description = description || ' (diubah untuk tes)'
    WHERE id = (
        SELECT id FROM public.auditguard_journal_lines
        WHERE journal_id = reversal_id
        ORDER BY id
        LIMIT 1
    );
    verification := public.auditguard_verify_journal(reversal_id);
    IF (verification->>'valid')::BOOLEAN IS NOT FALSE THEN
        RAISE EXCEPTION 'FAIL: checksum mismatch was not detected.';
    END IF;

    operation_rejected := FALSE;
    BEGIN
        PERFORM public.auditguard_post_journal(reversal_id);
    EXCEPTION WHEN OTHERS THEN
        operation_rejected := TRUE;
    END;
    IF NOT operation_rejected THEN
        RAISE EXCEPTION 'FAIL: tampered draft passed posting validation.';
    END IF;

    verification := public.auditguard_verify_journal(original_id);
    IF (verification->>'valid')::BOOLEAN IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: original posted journal changed during reversal.';
    END IF;

    RAISE NOTICE 'PASS: create, balance, checksum, authorization, posted lock, and reversal checks.';
END;
$$;

ROLLBACK;
