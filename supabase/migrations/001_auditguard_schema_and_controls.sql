-- AuditGuard Soal 3.2
-- Apply manually to a disposable Supabase project after reviewing this file.
-- Creates new auditguard_* tables; does not alter or delete existing tables/data.

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE TABLE IF NOT EXISTS public.auditguard_user_roles (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE RESTRICT,
    role TEXT NOT NULL CHECK (role IN ('maker', 'approver', 'admin')),
    display_name TEXT NOT NULL DEFAULT ''
);

CREATE TABLE IF NOT EXISTS public.auditguard_chart_of_accounts (
    account_code TEXT PRIMARY KEY,
    account_name TEXT NOT NULL
);

INSERT INTO public.auditguard_chart_of_accounts (account_code, account_name) VALUES
    ('1-1110', 'Kas Besar / Petty Cash'),
    ('1-1120', 'Bank BCA Operasional'),
    ('2-1100', 'Hutang Usaha Pihak Ketiga'),
    ('5-1100', 'Biaya Gaji & Tunjangan'),
    ('5-2100', 'Biaya Sewa Kantor & Gedung'),
    ('5-3100', 'Biaya Utilitas (Listrik/Air/Telp)'),
    ('5-4100', 'Biaya Pemeliharaan & Perbaikan'),
    ('5-5100', 'Biaya Perlengkapan Kantor'),
    ('6-1100', 'Biaya Administrasi Bank'),
    ('9-1100', 'Biaya Lain-lain')
ON CONFLICT (account_code) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.auditguard_journal_headers (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    voucher_no TEXT NOT NULL UNIQUE CHECK (length(trim(voucher_no)) > 0),
    voucher_date DATE NOT NULL,
    payee_name TEXT NOT NULL CHECK (length(trim(payee_name)) > 0),
    description TEXT NOT NULL CHECK (length(trim(description)) > 0),
    posting_status TEXT NOT NULL DEFAULT 'DRAFT'
        CHECK (posting_status IN ('DRAFT', 'POSTED')),
    created_by UUID NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    hash_checksum TEXT NOT NULL CHECK (hash_checksum ~ '^[0-9a-f]{64}$'),
    reverses_id BIGINT REFERENCES public.auditguard_journal_headers(id) ON DELETE RESTRICT,
    posted_by UUID REFERENCES auth.users(id) ON DELETE RESTRICT,
    posted_at TIMESTAMPTZ,
    CHECK (reverses_id IS NULL OR reverses_id <> id),
    CHECK (
        (posting_status = 'DRAFT' AND posted_by IS NULL AND posted_at IS NULL)
        OR
        (posting_status = 'POSTED' AND posted_by IS NOT NULL AND posted_at IS NOT NULL)
    )
);

CREATE UNIQUE INDEX IF NOT EXISTS auditguard_one_reversal_per_original
    ON public.auditguard_journal_headers (reverses_id)
    WHERE reverses_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.auditguard_journal_lines (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    journal_id BIGINT NOT NULL
        REFERENCES public.auditguard_journal_headers(id) ON DELETE RESTRICT,
    account_code TEXT NOT NULL
        REFERENCES public.auditguard_chart_of_accounts(account_code) ON DELETE RESTRICT,
    description TEXT NOT NULL DEFAULT '',
    debit NUMERIC(18, 2) NOT NULL DEFAULT 0 CHECK (debit >= 0),
    credit NUMERIC(18, 2) NOT NULL DEFAULT 0 CHECK (credit >= 0),
    CHECK (debit > 0 OR credit > 0)
);

CREATE INDEX IF NOT EXISTS auditguard_journal_lines_journal_id_idx
    ON public.auditguard_journal_lines (journal_id);

CREATE OR REPLACE FUNCTION public.auditguard_has_role(required_roles TEXT[])
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.auditguard_user_roles AS user_role
        WHERE user_role.user_id = auth.uid()
          AND user_role.role = ANY(required_roles)
    );
$$;

CREATE OR REPLACE FUNCTION public.auditguard_checksum(journal_id BIGINT)
RETURNS TEXT
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
    SELECT encode(
        extensions.digest(
            convert_to(
                jsonb_build_object(
                    'voucher_no', header.voucher_no,
                    'voucher_date', header.voucher_date::TEXT,
                    'payee_name', header.payee_name,
                    'description', header.description,
                    'created_by', header.created_by::TEXT,
                    'created_at', to_char(
                        header.created_at AT TIME ZONE 'UTC',
                        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
                    ),
                    'reverses_id', header.reverses_id,
                    'lines', COALESCE(
                        (
                            SELECT jsonb_agg(
                                jsonb_build_object(
                                    'account_code', line.account_code,
                                    'description', line.description,
                                    'debit', to_jsonb(trim_scale(line.debit)),
                                    'credit', to_jsonb(trim_scale(line.credit))
                                )
                                ORDER BY line.account_code, line.description,
                                    line.debit, line.credit
                            )
                            FROM public.auditguard_journal_lines AS line
                            WHERE line.journal_id = header.id
                        ),
                        '[]'::JSONB
                    )
                )::TEXT,
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    )
    FROM public.auditguard_journal_headers AS header
    WHERE header.id = journal_id;
$$;

CREATE OR REPLACE FUNCTION public.auditguard_protect_header()
RETURNS TRIGGER
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    line_count BIGINT;
    debit_total NUMERIC(18, 2);
    credit_total NUMERIC(18, 2);
    computed_checksum TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.posting_status = 'POSTED' THEN
            RAISE EXCEPTION 'Transaksi POSTED tidak boleh dihapus; gunakan reversing entry.';
        END IF;
        RETURN OLD;
    END IF;

    IF OLD.posting_status = 'POSTED' THEN
        RAISE EXCEPTION 'Transaksi POSTED tidak boleh diubah; gunakan reversing entry.';
    END IF;

    IF NEW.created_by IS DISTINCT FROM OLD.created_by
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.reverses_id IS DISTINCT FROM OLD.reverses_id THEN
        RAISE EXCEPTION 'Metadata audit transaksi tidak boleh diubah.';
    END IF;

    IF NEW.posting_status = 'POSTED' AND OLD.posting_status <> 'POSTED' THEN
        IF NOT public.auditguard_has_role(ARRAY['approver', 'admin'])
           OR NEW.posted_by IS DISTINCT FROM auth.uid() THEN
            RAISE EXCEPTION 'Posting memerlukan approver yang terautentikasi.';
        END IF;

        SELECT count(*), COALESCE(sum(debit), 0), COALESCE(sum(credit), 0)
        INTO line_count, debit_total, credit_total
        FROM public.auditguard_journal_lines
        WHERE journal_id = OLD.id;

        IF line_count = 0 OR debit_total <= 0 OR debit_total <> credit_total THEN
            RAISE EXCEPTION 'Jurnal harus memiliki detail dan total debit/kredit seimbang.';
        END IF;

        computed_checksum := public.auditguard_checksum(OLD.id);
        IF computed_checksum IS DISTINCT FROM OLD.hash_checksum THEN
            RAISE EXCEPTION 'Checksum tidak sesuai; posting dibatalkan.';
        END IF;
    ELSIF NEW.posting_status IS DISTINCT FROM OLD.posting_status THEN
        RAISE EXCEPTION 'Perubahan status transaksi tidak valid.';
    END IF;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.auditguard_protect_line()
RETURNS TRIGGER
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    parent_id BIGINT;
    parent_status TEXT;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.journal_id IS DISTINCT FROM OLD.journal_id THEN
        RAISE EXCEPTION 'Detail jurnal tidak boleh dipindahkan ke header lain.';
    END IF;

    parent_id := CASE WHEN TG_OP = 'INSERT' THEN NEW.journal_id ELSE OLD.journal_id END;
    SELECT posting_status INTO parent_status
    FROM public.auditguard_journal_headers
    WHERE id = parent_id
    FOR UPDATE;

    IF parent_status = 'POSTED' THEN
        RAISE EXCEPTION 'Detail transaksi POSTED tidak boleh ditambah, diubah, atau dihapus.';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS auditguard_header_immutability
    ON public.auditguard_journal_headers;
CREATE TRIGGER auditguard_header_immutability
BEFORE UPDATE OR DELETE ON public.auditguard_journal_headers
FOR EACH ROW EXECUTE FUNCTION public.auditguard_protect_header();

DROP TRIGGER IF EXISTS auditguard_line_immutability
    ON public.auditguard_journal_lines;
CREATE TRIGGER auditguard_line_immutability
BEFORE INSERT OR UPDATE OR DELETE ON public.auditguard_journal_lines
FOR EACH ROW EXECUTE FUNCTION public.auditguard_protect_line();

CREATE OR REPLACE FUNCTION public.auditguard_create_journal(
    p_voucher_no TEXT,
    p_voucher_date DATE,
    p_payee_name TEXT,
    p_description TEXT,
    p_lines JSONB
)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    current_user_id UUID := auth.uid();
    journal_id BIGINT;
    line JSONB;
    debit_value NUMERIC;
    credit_value NUMERIC;
    debit_total NUMERIC(18, 2) := 0;
    credit_total NUMERIC(18, 2) := 0;
    checksum_value TEXT;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'Autentikasi diperlukan.';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.auditguard_user_roles
        WHERE user_id = current_user_id AND role IN ('maker', 'approver', 'admin')
    ) THEN
        RAISE EXCEPTION 'Akun belum diberi peran AuditGuard.';
    END IF;
    IF p_voucher_no IS NULL OR length(trim(p_voucher_no)) = 0
       OR p_payee_name IS NULL OR length(trim(p_payee_name)) = 0
       OR p_description IS NULL OR length(trim(p_description)) = 0
       OR p_voucher_date IS NULL OR p_lines IS NULL
       OR jsonb_typeof(p_lines) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Header voucher dan baris jurnal wajib diisi.';
    END IF;

    INSERT INTO public.auditguard_journal_headers
        (voucher_no, voucher_date, payee_name, description, created_by, hash_checksum)
    VALUES
        (trim(p_voucher_no), p_voucher_date, trim(p_payee_name), trim(p_description),
         current_user_id, repeat('0', 64))
    RETURNING id INTO journal_id;

    FOR line IN SELECT value FROM jsonb_array_elements(p_lines)
    LOOP
        IF jsonb_typeof(line) <> 'object'
           OR NULLIF(trim(line->>'account_code'), '') IS NULL THEN
            RAISE EXCEPTION 'Setiap baris harus memiliki kode akun.';
        END IF;

        debit_value := COALESCE((line->>'debit')::NUMERIC, 0);
        credit_value := COALESCE((line->>'credit')::NUMERIC, 0);
        IF debit_value::TEXT IN ('NaN', 'Infinity', '-Infinity')
           OR credit_value::TEXT IN ('NaN', 'Infinity', '-Infinity')
           OR abs(debit_value) >= 10000000000000000
           OR abs(credit_value) >= 10000000000000000
           OR debit_value < 0 OR credit_value < 0
           OR debit_value <> round(debit_value, 2)
           OR credit_value <> round(credit_value, 2)
           OR debit_value = 0 AND credit_value = 0 THEN
            RAISE EXCEPTION 'Nominal jurnal harus valid, positif/nol, dan maksimal 2 desimal.';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.auditguard_chart_of_accounts
            WHERE account_code = trim(line->>'account_code')
        ) THEN
            RAISE EXCEPTION 'Kode akun tidak terdaftar: %', line->>'account_code';
        END IF;

        INSERT INTO public.auditguard_journal_lines
            (journal_id, account_code, description, debit, credit)
        VALUES
            (journal_id, trim(line->>'account_code'),
             COALESCE(line->>'description', ''), debit_value, credit_value);
        debit_total := debit_total + debit_value;
        credit_total := credit_total + credit_value;
    END LOOP;

    IF debit_total <= 0 OR debit_total <> credit_total THEN
        RAISE EXCEPTION 'Jurnal harus seimbang dan totalnya lebih besar dari nol.';
    END IF;

    checksum_value := public.auditguard_checksum(journal_id);
    UPDATE public.auditguard_journal_headers
    SET hash_checksum = checksum_value
    WHERE id = journal_id;

    RETURN jsonb_build_object(
        'id', journal_id,
        'voucher_no', trim(p_voucher_no),
        'posting_status', 'DRAFT',
        'created_by', current_user_id,
        'hash_checksum', checksum_value
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.auditguard_update_draft(
    p_journal_id BIGINT,
    p_voucher_no TEXT,
    p_voucher_date DATE,
    p_payee_name TEXT,
    p_description TEXT,
    p_lines JSONB
)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    header public.auditguard_journal_headers%ROWTYPE;
    current_user_id UUID := auth.uid();
    line JSONB;
    debit_value NUMERIC;
    credit_value NUMERIC;
    debit_total NUMERIC(18, 2) := 0;
    credit_total NUMERIC(18, 2) := 0;
    checksum_value TEXT;
BEGIN
    SELECT * INTO header
    FROM public.auditguard_journal_headers
    WHERE id = p_journal_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher tidak ditemukan.';
    END IF;
    IF header.posting_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Hanya voucher DRAFT yang dapat diperbarui.';
    END IF;
    IF header.created_by <> current_user_id
       AND NOT public.auditguard_has_role(ARRAY['approver', 'admin']) THEN
        RAISE EXCEPTION 'Tidak berwenang mengubah voucher ini.';
    END IF;
    IF p_voucher_no IS NULL OR length(trim(p_voucher_no)) = 0
       OR p_payee_name IS NULL OR length(trim(p_payee_name)) = 0
       OR p_description IS NULL OR length(trim(p_description)) = 0
       OR p_voucher_date IS NULL OR p_lines IS NULL
       OR jsonb_typeof(p_lines) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'Header voucher dan baris jurnal wajib diisi.';
    END IF;

    UPDATE public.auditguard_journal_headers
    SET voucher_no = trim(p_voucher_no), voucher_date = p_voucher_date,
        payee_name = trim(p_payee_name), description = trim(p_description)
    WHERE id = p_journal_id;
    DELETE FROM public.auditguard_journal_lines AS line
    WHERE line.journal_id = p_journal_id;

    FOR line IN SELECT value FROM jsonb_array_elements(p_lines)
    LOOP
        IF jsonb_typeof(line) <> 'object'
           OR NULLIF(trim(line->>'account_code'), '') IS NULL THEN
            RAISE EXCEPTION 'Setiap baris harus memiliki kode akun.';
        END IF;
        debit_value := COALESCE((line->>'debit')::NUMERIC, 0);
        credit_value := COALESCE((line->>'credit')::NUMERIC, 0);
        IF debit_value::TEXT IN ('NaN', 'Infinity', '-Infinity')
           OR credit_value::TEXT IN ('NaN', 'Infinity', '-Infinity')
           OR abs(debit_value) >= 10000000000000000
           OR abs(credit_value) >= 10000000000000000
           OR debit_value < 0 OR credit_value < 0
           OR debit_value <> round(debit_value, 2)
           OR credit_value <> round(credit_value, 2)
           OR debit_value = 0 AND credit_value = 0 THEN
            RAISE EXCEPTION 'Nominal jurnal harus valid, positif/nol, dan maksimal 2 desimal.';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM public.auditguard_chart_of_accounts
            WHERE account_code = trim(line->>'account_code')
        ) THEN
            RAISE EXCEPTION 'Kode akun tidak terdaftar: %', line->>'account_code';
        END IF;
        INSERT INTO public.auditguard_journal_lines
            (journal_id, account_code, description, debit, credit)
        VALUES
            (p_journal_id, trim(line->>'account_code'),
             COALESCE(line->>'description', ''), debit_value, credit_value);
        debit_total := debit_total + debit_value;
        credit_total := credit_total + credit_value;
    END LOOP;
    IF debit_total <= 0 OR debit_total <> credit_total THEN
        RAISE EXCEPTION 'Jurnal harus seimbang dan totalnya lebih besar dari nol.';
    END IF;

    checksum_value := public.auditguard_checksum(p_journal_id);
    UPDATE public.auditguard_journal_headers
    SET hash_checksum = checksum_value
    WHERE id = p_journal_id;
    RETURN jsonb_build_object('id', p_journal_id, 'hash_checksum', checksum_value);
END;
$$;

CREATE OR REPLACE FUNCTION public.auditguard_post_journal(p_journal_id BIGINT)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    header public.auditguard_journal_headers%ROWTYPE;
    current_user_id UUID := auth.uid();
    computed_checksum TEXT;
    debit_total NUMERIC(18, 2);
    credit_total NUMERIC(18, 2);
    line_count BIGINT;
BEGIN
    IF current_user_id IS NULL
       OR NOT public.auditguard_has_role(ARRAY['approver', 'admin']) THEN
        RAISE EXCEPTION 'Posting memerlukan peran approver atau admin.';
    END IF;
    SELECT * INTO header
    FROM public.auditguard_journal_headers
    WHERE id = p_journal_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher tidak ditemukan.';
    END IF;
    IF header.posting_status <> 'DRAFT' THEN
        RAISE EXCEPTION 'Hanya voucher DRAFT yang dapat diposting.';
    END IF;

    SELECT count(*), COALESCE(sum(debit), 0), COALESCE(sum(credit), 0)
    INTO line_count, debit_total, credit_total
    FROM public.auditguard_journal_lines AS line
    WHERE line.journal_id = p_journal_id;
    IF line_count = 0 OR debit_total <= 0 OR debit_total <> credit_total THEN
        RAISE EXCEPTION 'Jurnal harus memiliki detail dan total debit/kredit seimbang.';
    END IF;
    computed_checksum := public.auditguard_checksum(p_journal_id);
    IF computed_checksum <> header.hash_checksum THEN
        RAISE EXCEPTION 'Checksum tidak sesuai; posting dibatalkan.';
    END IF;

    UPDATE public.auditguard_journal_headers
    SET posting_status = 'POSTED', posted_by = current_user_id, posted_at = now()
    WHERE id = p_journal_id;
    RETURN jsonb_build_object(
        'id', p_journal_id, 'posting_status', 'POSTED',
        'posted_by', current_user_id, 'posted_at', now()
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.auditguard_reverse_journal(
    p_journal_id BIGINT,
    p_reversal_voucher_no TEXT,
    p_reversal_date DATE DEFAULT CURRENT_DATE
)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    original public.auditguard_journal_headers%ROWTYPE;
    current_user_id UUID := auth.uid();
    reversal_id BIGINT;
    line RECORD;
    checksum_value TEXT;
BEGIN
    IF current_user_id IS NULL
       OR NOT public.auditguard_has_role(ARRAY['approver', 'admin']) THEN
        RAISE EXCEPTION 'Pembalikan memerlukan peran approver atau admin.';
    END IF;
    SELECT * INTO original
    FROM public.auditguard_journal_headers
    WHERE id = p_journal_id
    FOR UPDATE;
    IF NOT FOUND OR original.posting_status <> 'POSTED' THEN
        RAISE EXCEPTION 'Hanya transaksi POSTED yang dapat dibalik.';
    END IF;
    IF public.auditguard_checksum(p_journal_id) <> original.hash_checksum THEN
        RAISE EXCEPTION 'Checksum jurnal asal tidak sesuai; pembalikan dibatalkan.';
    END IF;
    IF p_reversal_voucher_no IS NULL
       OR length(trim(p_reversal_voucher_no)) = 0
       OR p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'Nomor dan tanggal voucher pembalik wajib diisi.';
    END IF;

    INSERT INTO public.auditguard_journal_headers
        (voucher_no, voucher_date, payee_name, description, created_by,
         hash_checksum, reverses_id)
    VALUES
        (trim(p_reversal_voucher_no), p_reversal_date, original.payee_name,
         'Pembalikan voucher ' || original.voucher_no, current_user_id,
         repeat('0', 64), original.id)
    RETURNING id INTO reversal_id;

    FOR line IN
        SELECT account_code, description, debit, credit
        FROM public.auditguard_journal_lines
        WHERE journal_id = original.id
        ORDER BY id
    LOOP
        INSERT INTO public.auditguard_journal_lines
            (journal_id, account_code, description, debit, credit)
        VALUES
            (reversal_id, line.account_code,
             'Pembalikan: ' || line.description, line.credit, line.debit);
    END LOOP;

    checksum_value := public.auditguard_checksum(reversal_id);
    UPDATE public.auditguard_journal_headers
    SET hash_checksum = checksum_value
    WHERE id = reversal_id;
    RETURN jsonb_build_object(
        'id', reversal_id, 'reverses_id', original.id,
        'posting_status', 'DRAFT', 'hash_checksum', checksum_value
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.auditguard_verify_journal(p_journal_id BIGINT)
RETURNS JSONB
LANGUAGE PLPGSQL
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    header public.auditguard_journal_headers%ROWTYPE;
    computed_checksum TEXT;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Autentikasi diperlukan.';
    END IF;
    SELECT * INTO header
    FROM public.auditguard_journal_headers
    WHERE id = p_journal_id
      AND (
          created_by = auth.uid()
          OR public.auditguard_has_role(ARRAY['approver', 'admin'])
      );
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Voucher tidak ditemukan atau tidak berwenang diakses.';
    END IF;
    computed_checksum := public.auditguard_checksum(p_journal_id);
    RETURN jsonb_build_object(
        'id', p_journal_id,
        'valid', computed_checksum = header.hash_checksum,
        'stored_checksum', header.hash_checksum,
        'computed_checksum', computed_checksum
    );
END;
$$;

ALTER TABLE public.auditguard_user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auditguard_chart_of_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auditguard_journal_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auditguard_journal_lines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS auditguard_user_roles_read_own
    ON public.auditguard_user_roles;
CREATE POLICY auditguard_user_roles_read_own
ON public.auditguard_user_roles FOR SELECT TO authenticated
USING (user_id = auth.uid() OR public.auditguard_has_role(ARRAY['admin']));

DROP POLICY IF EXISTS auditguard_accounts_read_authenticated
    ON public.auditguard_chart_of_accounts;
CREATE POLICY auditguard_accounts_read_authenticated
ON public.auditguard_chart_of_accounts FOR SELECT TO authenticated
USING (true);

DROP POLICY IF EXISTS auditguard_headers_read_authorized
    ON public.auditguard_journal_headers;
CREATE POLICY auditguard_headers_read_authorized
ON public.auditguard_journal_headers FOR SELECT TO authenticated
USING (
    created_by = auth.uid()
    OR public.auditguard_has_role(ARRAY['approver', 'admin'])
);

DROP POLICY IF EXISTS auditguard_lines_read_authorized
    ON public.auditguard_journal_lines;
CREATE POLICY auditguard_lines_read_authorized
ON public.auditguard_journal_lines FOR SELECT TO authenticated
USING (
    EXISTS (
        SELECT 1 FROM public.auditguard_journal_headers AS header
        WHERE header.id = journal_id
          AND (
              header.created_by = auth.uid()
              OR public.auditguard_has_role(ARRAY['approver', 'admin'])
          )
    )
);

REVOKE ALL ON TABLE
    public.auditguard_user_roles,
    public.auditguard_chart_of_accounts,
    public.auditguard_journal_headers,
    public.auditguard_journal_lines
FROM anon, authenticated;
REVOKE ALL ON SEQUENCE
    public.auditguard_journal_headers_id_seq,
    public.auditguard_journal_lines_id_seq
FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE
    public.auditguard_user_roles,
    public.auditguard_chart_of_accounts,
    public.auditguard_journal_headers,
    public.auditguard_journal_lines
TO authenticated;

REVOKE ALL ON FUNCTION public.auditguard_has_role(TEXT[]) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditguard_checksum(BIGINT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditguard_protect_header() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditguard_protect_line() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditguard_create_journal(TEXT, DATE, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditguard_update_draft(BIGINT, TEXT, DATE, TEXT, TEXT, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditguard_post_journal(BIGINT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditguard_reverse_journal(BIGINT, TEXT, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditguard_verify_journal(BIGINT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.auditguard_has_role(TEXT[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.auditguard_create_journal(TEXT, DATE, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.auditguard_update_draft(BIGINT, TEXT, DATE, TEXT, TEXT, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.auditguard_post_journal(BIGINT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.auditguard_reverse_journal(BIGINT, TEXT, DATE) TO authenticated;
GRANT EXECUTE ON FUNCTION public.auditguard_verify_journal(BIGINT) TO authenticated;
