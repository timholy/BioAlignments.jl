using Test
using BioAlignments
using BioSymbols
import BioSequences: @dna_str, @aa_str

# Generate a random valid alignment of a sequence of length n against a sequence
# of length m. If `glob` is true, generate a global alignment, if false, a local
# alignment.
function random_alignment(m, n, glob=true)
    match_ops = [OP_MATCH, OP_SEQ_MATCH, OP_SEQ_MISMATCH]
    insert_ops = [OP_INSERT, OP_SOFT_CLIP, OP_HARD_CLIP]
    delete_ops = [OP_DELETE, OP_SKIP]
    ops = vcat(match_ops, insert_ops, delete_ops)

    # This is just a random walk on a m-by-n matrix, where steps are either
    # (+1,0), (0,+1), (+1,+1). To make somewhat more realistic alignments, it's
    # biased towards going in the same direction. Local alignments have a random
    # start and end time, global alignments always start at (0,0) and end at
    # (m,n).

    # probability of choosing the same direction as the last step
    straight_pr = 0.9

    op = OP_MATCH
    if glob
        i = 0
        j = 0
        i_end = m
        j_end = n
    else
        i = rand(1:m-1)
        j = rand(1:n-1)
        i_end = rand(i+1:m)
        j_end = rand(j+1:n)
    end

    alnpos = 0
    path = AlignmentAnchor[AlignmentAnchor(i, j, alnpos, OP_START)]
    while (glob && i < i_end && j < j_end) || (!glob && (i < i_end || j < j_end))
        straight = rand() < straight_pr
        iprev, jprev = i, j
        if i == i_end
            if !straight
                op = rand(delete_ops)
            end
            j += 1
        elseif j == j_end
            if !straight
                op = rand(inset_ops)
            end
            i += 1
        else
            if !straight
                op = rand(ops)
            end

            if isdeleteop(op)
                j += 1
            elseif isinsertop(op)
                i += 1
            else
                i += 1
                j += 1
            end
        end
        alnpos += max(i - iprev, j - jprev)
        push!(path, AlignmentAnchor(i, j, alnpos, op))
    end

    return path
end

# Make an Alignment from a path returned by random_alignment. Converting from
# path to Alignment is just done by removing redundant nodes from the path.
function anchors_from_path(path)
    anchors = AlignmentAnchor[]
    for k in 1:length(path)
        if k == length(path) || path[k].op != path[k+1].op
            push!(anchors, path[k])
        end
    end
    return anchors
end

@testset "Alignments" begin
    @testset "Operations" begin
        for (char, op) in [
                ('M', OP_MATCH),
                ('I', OP_INSERT),
                ('D', OP_DELETE),
                ('N', OP_SKIP),
                ('S', OP_SOFT_CLIP),
                ('H', OP_HARD_CLIP),
                ('P', OP_PAD),
                ('=', OP_SEQ_MATCH),
                ('X', OP_SEQ_MISMATCH),
                ('B', OP_BACK),
                ('0', OP_START)]
            @test convert(Operation, char) === op
            @test convert(Char, op) === char
            @test sprint(print, op) == string(char)
        end
        @test_throws ArgumentError convert(Operation, 'm')
        @test_throws ArgumentError convert(Operation, '7')
        @test_throws ArgumentError convert(Operation, 'A')
        @test_throws ArgumentError convert(Char, reinterpret(Operation, reinterpret(UInt8, OP_START)+UInt8(1)))
        @test_throws ArgumentError convert(Char, BioAlignments.OP_INVALID)

        # Test the Base.show method.
        @test sprint(show, OP_MATCH)        == "OP_MATCH"
        @test sprint(show, OP_INSERT)       == "OP_INSERT"
        @test sprint(show, OP_DELETE)       == "OP_DELETE"
        @test sprint(show, OP_SKIP)         == "OP_SKIP"
        @test sprint(show, OP_SOFT_CLIP)    == "OP_SOFT_CLIP"
        @test sprint(show, OP_HARD_CLIP)    == "OP_HARD_CLIP"
        @test sprint(show, OP_PAD)          == "OP_PAD"
        @test sprint(show, OP_SEQ_MATCH)    == "OP_SEQ_MATCH"
        @test sprint(show, OP_SEQ_MISMATCH) == "OP_SEQ_MISMATCH"
        @test sprint(show, OP_BACK)         == "OP_BACK"
        @test sprint(show, OP_START)        == "OP_START"
        @test sprint(show, BioAlignments.OP_INVALID) == "Invalid Operation"
    end

    @testset "AlignmentAnchor" begin
        anchor = AlignmentAnchor(1, 2, 3, OP_MATCH)
        @test string(anchor) == "AlignmentAnchor(1, 2, 3, 'M')"
    end

    @testset "Alignment" begin
        # alignments with nonsense operations
        @test_throws Exception Alignment(AlignmentAnchor[
            Operation(0, 0, 0, OP_START),
            Operation(100, 100, 100, convert(Operation, 0xfa))])

        # test bad alignment anchors by swapping nodes in paths
        for _ in 1:100
            path = random_alignment(rand(1000:10000), rand(1000:10000))
            anchors = anchors_from_path(path)
            n = length(anchors)
            n < 3 && continue
            i = rand(2:n-1)
            j = rand(i+1:n)
            anchors[i], anchors[j] = anchors[j], anchors[i]
            @test_throws Exception Alignment(anchors)
        end

        # test bad alignment anchors by swapping operations
        for _ in 1:100
            path = random_alignment(rand(1000:10000), rand(1000:10000))
            anchors = anchors_from_path(path)
            n = length(anchors)
            n < 3 && continue
            i = rand(2:n-1)
            j = rand(i+1:n)
            u = anchors[i]
            v = anchors[j]
            if (ismatchop(u.op) && ismatchop(v.op)) ||
               (isinsertop(u.op) && isinsertop(v.op)) ||
               (isdeleteop(u.op) && isdeleteop(v.op))
                continue
            end
            anchors[i] = AlignmentAnchor(u.seqpos, u.refpos, u.alnpos, v.op)
            anchors[j] = AlignmentAnchor(v.seqpos, v.refpos, v.alnpos, u.op)
            @test_throws Exception Alignment(anchors)
        end

        # cigar string round-trip
        for _ in 1:100
            path = random_alignment(rand(1000:10000), rand(1000:10000))
            anchors = anchors_from_path(path)
            aln = Alignment(anchors)
            cig = cigar(aln)
            @test Alignment(cig, aln.anchors[1].seqpos + 1,
                            aln.anchors[1].refpos + 1) == aln
        end
    end

    @testset "AlignedSequence" begin
        #               0   4        9  12 15     19
        #               |   |        |  |  |      |
        #     query:     TGGC----ATCATTTAACG---CAAG
        # reference: AGGGTGGCATTTATCAG---ACGTTTCGAGAC
        #               |   |   |    |     |  |   |
        #               4   8   12   17    20 23  27
        anchors = [
            AlignmentAnchor( 0,  4,  0, OP_START),
            AlignmentAnchor( 4,  8,  4, OP_MATCH),
            AlignmentAnchor( 4, 12,  8, OP_DELETE),
            AlignmentAnchor( 9, 17, 13, OP_MATCH),
            AlignmentAnchor(12, 17, 16, OP_INSERT),
            AlignmentAnchor(15, 20, 19, OP_MATCH),
            AlignmentAnchor(15, 23, 22, OP_DELETE),
            AlignmentAnchor(19, 27, 26, OP_MATCH)
        ]
        query = "TGGCATCATTTAACGCAAG"
        alnseq = AlignedSequence(query, anchors)
        @test BioAlignments.first(alnseq) ==  5
        @test BioAlignments.last(alnseq)  == 27
        # OP_MATCH
        for (seqpos, refpos, alnpos) in [(1, 5, 1), (2, 6, 2), (4, 8, 4), (13, 18, 17), (19, 27, 26)]
            @test seq2ref(alnseq, seqpos) == (refpos, OP_MATCH)
            @test ref2seq(alnseq, refpos) == (seqpos, OP_MATCH)
            @test seq2aln(alnseq, seqpos) == (alnpos, OP_MATCH)
            @test ref2aln(alnseq, refpos) == (alnpos, OP_MATCH)
            @test aln2seq(alnseq, alnpos) == (seqpos, OP_MATCH)
            @test aln2ref(alnseq, alnpos) == (refpos, OP_MATCH)
        end
        # OP_INSERT
        @test seq2ref(alnseq, 10) == (17, OP_INSERT)
        @test seq2ref(alnseq, 11) == (17, OP_INSERT)
        @test seq2aln(alnseq, 10) == (14, OP_INSERT)
        @test seq2aln(alnseq, 11) == (15, OP_INSERT)
        @test aln2seq(alnseq, 14) == (10, OP_INSERT)
        @test aln2seq(alnseq, 15) == (11, OP_INSERT)
        @test aln2ref(alnseq, 14) == (17, OP_INSERT)
        @test aln2ref(alnseq, 15) == (17, OP_INSERT)
        # OP_DELETE
        @test ref2seq(alnseq,  9) == ( 4, OP_DELETE)
        @test ref2seq(alnseq, 10) == ( 4, OP_DELETE)
        @test ref2aln(alnseq, 9) == (5, OP_DELETE)
        @test ref2aln(alnseq, 10) == (6, OP_DELETE)
        @test aln2seq(alnseq, 5) == (4, OP_DELETE)
        @test aln2seq(alnseq, 6) == (4, OP_DELETE)
        @test aln2ref(alnseq, 5) == (9, OP_DELETE)
        @test aln2ref(alnseq, 6) == (10, OP_DELETE)
        @test ref2seq(alnseq, 23) == (15, OP_DELETE)
        @test ref2aln(alnseq, 23) == (22, OP_DELETE)
        @test aln2seq(alnseq, 22) == (15, OP_DELETE)
        @test aln2ref(alnseq, 22) == (23, OP_DELETE)
        @test sprint(show, alnseq) == """
        ·············---··········
        TGGC----ATCATTTAACG---CAAG"""

        seq = dna"ACGG--TGAAAGGT"
        ref = dna"-CGGGGA----TTT"
        alnseq = AlignedSequence(seq, ref)
        @test BioAlignments.first(alnseq) == 1
        @test BioAlignments.last(alnseq)  == 9
        @test alnseq.aln.anchors == [
             AlignmentAnchor( 0, 0,  0, '0')
             AlignmentAnchor( 1, 0,  1, 'I')
             AlignmentAnchor( 4, 3,  4, '=')
             AlignmentAnchor( 4, 5,  6, 'D')
             AlignmentAnchor( 5, 6,  7, 'X')
             AlignmentAnchor( 9, 6, 11, 'I')
             AlignmentAnchor(11, 8, 13, 'X')
             AlignmentAnchor(12, 9, 14, '=')
        ]
        @test sprint(show, alnseq) == """
        -······----···
        ACGG--TGAAAGGT"""
    end
end


# generate test cases from two aligned sequences
function alnscore(::Type{S}, affinegap::AffineGapScoreModel{T}, alnstr::AbstractString, clip::Bool) where {S,T}
    gap_open = affinegap.gap_open
    gap_extend = affinegap.gap_extend
    lines = split(chomp(alnstr), '\n')
    a, b = lines[1:2]
    m = length(a)
    @assert m == length(b)

    if length(lines) == 2
        start = 1
        while start ≤ m && a[start] == ' ' || b[start] == ' '
            start += 1
        end
        stop = start
        while stop + 1 ≤ m && !(a[stop+1] == ' ' || b[stop+1] == ' ')
            stop += 1
        end
    elseif length(lines) == 3
        start = findfirst(isequal('^'), lines[3])
        stop = findlast(isequal('^'), lines[3])
    else
        error("invalid alignment string")
    end

    score = T(0)
    gap_extending_a = false
    gap_extending_b = false
    for i in start:stop
        if a[i] == '-'
            score += gap_extending_a ? gap_extend : (gap_open + gap_extend)
            gap_extending_a = true
        elseif b[i] == '-'
            score += gap_extending_b ? gap_extend : (gap_open + gap_extend)
            gap_extending_b = true
        else
            score += affinegap.submat[a[i],b[i]]
            gap_extending_a = false
            gap_extending_b = false
        end
    end
    sa = S(replace(a, r"\s|-" => ""))
    sb = S(replace(b, r"\s|-" => ""))
    return sa, sb, score, clip ? string(a[start:stop], '\n', b[start:stop]) : string(a, '\n', b)
end

function alnscore(affinegap::AffineGapScoreModel, alnstr::AbstractString; clip=true)
    return alnscore(String, affinegap, alnstr, clip)
end

function alndistance(::Type{S}, cost::CostModel{T}, alnstr::AbstractString) where {S,T}
    lines = split(chomp(alnstr), '\n')
    @assert length(lines) == 2
    a, b = lines
    m = length(a)
    @assert length(b) == m
    dist = T(0)
    for i in 1:m
        if a[i] == '-'
            dist += cost.deletion
        elseif b[i] == '-'
            dist += cost.insertion
        else
            dist += cost.submat[a[i],b[i]]
        end
    end
    return S(replace(a, r"\s|-" => "")), S(replace(b, r"\s|-" => "")), dist
end

function alndistance(cost::CostModel, alnstr::AbstractString)
    return alndistance(String, cost, alnstr)
end

function alignedpair(alnres)
    aln = alignment(alnres)
    a = aln.a
    b = aln.b
    anchors = a.aln.anchors
    buf = IOBuffer()
    print_seq(buf, a, anchors)
    println(buf)
    print_ref(buf, b, anchors)
    return String(take!(buf))
end

function print_seq(io, seq, anchors)
    for i in 2:length(anchors)
        if ismatchop(anchors[i].op) || isinsertop(anchors[i].op)
            for j in anchors[i-1].seqpos+1:anchors[i].seqpos
                print(io, seq.seq[j])
            end
        elseif isdeleteop(anchors[i].op)
            for _ in anchors[i-1].refpos+1:anchors[i].refpos
                print(io, '-')
            end
        end
    end
end

function print_ref(io, ref, anchors)
    for i in 2:length(anchors)
        if ismatchop(anchors[i].op) || isdeleteop(anchors[i].op)
            for j in anchors[i-1].refpos+1:anchors[i].refpos
                print(io, ref[j])
            end
        elseif isinsertop(anchors[i].op)
            for _ in anchors[i-1].seqpos+1:anchors[i].seqpos
                print(io, '-')
            end
        end
    end
end

@testset "PairwiseAlignment" begin
    @testset "SubstitutionMatrix" begin
        # DNA
        @test EDNAFULL[DNA_A,DNA_A] ===  5
        @test EDNAFULL[DNA_G,DNA_G] ===  5
        @test EDNAFULL[DNA_A,DNA_G] === -4
        @test EDNAFULL[DNA_G,DNA_A] === -4
        @test EDNAFULL[DNA_M,DNA_T] === -4
        @test EDNAFULL[DNA_M,DNA_C] ===  1

        # amino acid
        @test BLOSUM62[AA_A,AA_R] === -1
        @test BLOSUM62[AA_R,AA_A] === -1
        @test BLOSUM62[AA_R,AA_R] ===  5
        @test BLOSUM62[AA_O,AA_R] ===  0  # default
        @test BLOSUM62[AA_R,AA_O] ===  0  # default

        # update
        myblosum = copy(BLOSUM62)
        @test myblosum[AA_A,AA_R] === -1
        myblosum[AA_A,AA_R] = 10
        @test myblosum[AA_A,AA_R] === 10

        @test BLOSUM62[AA_O,AA_R] ===  0  # default
        myblosum[AA_O,AA_R] = -3
        @test myblosum[AA_O,AA_R] === -3

        @test convert(Matrix, BioAlignments.load_submat(AminoAcid, "BLOSUM62")) == convert(Matrix, BLOSUM62)

        submat = SubstitutionMatrix(DNA, rand(Float64, 15, 15))
        @test isa(submat, SubstitutionMatrix{DNA,Float64})

        submat = SubstitutionMatrix(
            Dict((DNA_A, DNA_T) => 5, (DNA_T, DNA_A) => 4),
            default_match=0,
            default_mismatch=-1)
        @test submat[DNA_A,DNA_T] === 5
        @test submat[DNA_T,DNA_A] === 4
        @test submat[DNA_A,DNA_A] === 0
        @test submat[DNA_A,DNA_G] === -1

        submat = DichotomousSubstitutionMatrix(5, -4)
        @test isa(submat, DichotomousSubstitutionMatrix{Int})
        @test sprint(show, submat) == """
        DichotomousSubstitutionMatrix{Int64}:
             match =  5
          mismatch = -4"""
        submat = convert(SubstitutionMatrix{DNA,Int}, submat)
        @test submat[DNA_A,DNA_A] ===  5
        @test submat[DNA_C,DNA_C] ===  5
        @test submat[DNA_A,DNA_C] === -4
        @test submat[DNA_C,DNA_A] === -4

        try
            print(IOBuffer(), EDNAFULL)
            print(IOBuffer(), BLOSUM62)
            # no error
            @test true
        catch
            @test false
        end
    end

    @testset "AffineGapScoreModel" begin
        # predefined substitution matrix
        for affinegap in [AffineGapScoreModel(BLOSUM62, -10, -1),
                          AffineGapScoreModel(BLOSUM62, gap_open=-10, gap_extend=-1),
                          AffineGapScoreModel(BLOSUM62, gap_open_penalty=10, gap_extend_penalty=1)]
            @test affinegap.gap_open == -10
            @test affinegap.gap_extend == -1
            @test typeof(affinegap) == AffineGapScoreModel{Int}
        end
        @test_throws ArgumentError AffineGapScoreModel(BLOSUM62)
        @test_throws ArgumentError AffineGapScoreModel(BLOSUM62, gap_open=-10)
        @test_throws ArgumentError AffineGapScoreModel(BLOSUM62, gap_extend=-1)

        # matrix
        submat = SubstitutionMatrix(DNA, rand(Float64, 15, 15))
        for affinegap in [AffineGapScoreModel(submat, -3, -1),
                          AffineGapScoreModel(submat, gap_open=-3, gap_extend=-1),
                          AffineGapScoreModel(submat, gap_open_penalty=3, gap_extend_penalty=1)]
            @test affinegap.gap_open == -3
            @test affinegap.gap_extend == -1
            @test typeof(affinegap) == AffineGapScoreModel{Float64}
        end

        affinegap = AffineGapScoreModel(match=3, mismatch=-3, gap_open=-5, gap_extend=-2)
        @test affinegap.gap_open == -5
        @test affinegap.gap_extend == -2
        @test typeof(affinegap) == AffineGapScoreModel{Int}
        @test sprint(show, affinegap) == """
        AffineGapScoreModel{Int64}:
               match = 3
            mismatch = -3
            gap_open = -5
          gap_extend = -2"""

    end

    @testset "CostModel" begin
        submat = SubstitutionMatrix(DNA, rand(Int, 15, 15))
        for cost in [CostModel(submat, 5, 6),
                     CostModel(submat, insertion=5, deletion=6)]
            @test cost.insertion == 5
            @test cost.deletion == 6
            @test typeof(cost) == CostModel{Int}
        end
        @test_throws ArgumentError CostModel(submat, insertion=5)
        @test_throws ArgumentError CostModel(submat, deletion=5)

        cost = CostModel(match=0, mismatch=3, insertion=5, deletion=6)
        @test cost.insertion == 5
        @test cost.deletion == 6
        @test typeof(cost) == CostModel{Int}
    end

    @testset "Alignment" begin
        anchors = [
            AlignmentAnchor(0, 0, 0, OP_START),
            AlignmentAnchor(3, 3, 3, OP_SEQ_MATCH)
        ]
        seq = AlignedSequence("ACG", anchors)
        ref = "ACG"
        aln = PairwiseAlignment(seq, ref)
        @test collect(aln) == [('A', 'A'), ('C', 'C'), ('G', 'G')]
        result = PairwiseAlignmentResult(3, true, seq, ref)
        @test isa(result, PairwiseAlignmentResult) == true
        @test isa(alignment(result), PairwiseAlignment) == true
        @test score(result) == 3
        @test hasalignment(result) == true
    end

    @testset "count_<ops>" begin
        # anchors are derived from an alignment:
        #   seq: ACG---TGCAGAATTT
        #        |     || || ||
        #   ref: AAAATTTGAAGTAT--
        a = dna"ACGTGCAGAATTT"
        b = dna"AAAATTTGAAGTAT"
        anchors = [
            AlignmentAnchor( 0,  0,  0, '0'),
            AlignmentAnchor( 1,  1,  1, '='),
            AlignmentAnchor( 3,  3,  3, 'X'),
            AlignmentAnchor( 3,  6,  6, 'D'),
            AlignmentAnchor( 5,  8,  8, '='),
            AlignmentAnchor( 6,  9,  9, 'X'),
            AlignmentAnchor( 8, 11, 11, '='),
            AlignmentAnchor( 9, 12, 12, 'X'),
            AlignmentAnchor(11, 14, 14, '='),
            AlignmentAnchor(13, 14, 16, 'I')
        ]
        aln = PairwiseAlignment(AlignedSequence(a, anchors), b)
        @test count_matches(aln) == 7
        @test count_mismatches(aln) == 4
        @test count_insertions(aln) == 2
        @test count_deletions(aln) == 3
        @test count_aligned(aln) == 16
    end

    @testset "Interfaces" begin
        seq = dna"ACGTATAGT"
        ref = dna"ATCGTATTGGT"
        # seq:  1 A-CGTATAG-T  9
        #         | ||||| | |
        # ref:  1 ATCGTATTGGT 11
        model = AffineGapScoreModel(EDNAFULL, gap_open=-4, gap_extend=-1)
        result = pairalign(GlobalAlignment(), seq, ref, model)
        @test isa(result, PairwiseAlignmentResult)
        aln = alignment(result)
        @test isa(aln, PairwiseAlignment)
        @test seq2ref(aln, 1) == (1, OP_SEQ_MATCH)
        @test seq2ref(aln, 2) == (3, OP_SEQ_MATCH)
        @test seq2ref(aln, 3) == (4, OP_SEQ_MATCH)
        @test seq2aln(aln, 1) == (1, OP_SEQ_MATCH)
        @test seq2aln(aln, 2) == (3, OP_SEQ_MATCH)
        @test seq2aln(aln, 3) == (4, OP_SEQ_MATCH)
        @test aln2seq(aln, 1) == (1, OP_SEQ_MATCH)
        @test aln2seq(aln, 2) == (1, OP_DELETE)
        @test aln2seq(aln, 3) == (2, OP_SEQ_MATCH)
        @test ref2seq(aln, 1) == (1, OP_SEQ_MATCH)
        @test ref2seq(aln, 2) == (1, OP_DELETE)
        @test ref2seq(aln, 3) == (2, OP_SEQ_MATCH)
        @test ref2aln(aln, 1) == (1, OP_SEQ_MATCH)
        @test ref2aln(aln, 2) == (2, OP_DELETE)
        @test ref2aln(aln, 3) == (3, OP_SEQ_MATCH)
        @test aln2ref(aln, 1) == (1, OP_SEQ_MATCH)
        @test aln2ref(aln, 2) == (2, OP_DELETE)
        @test aln2ref(aln, 3) == (3, OP_SEQ_MATCH)
    end

    @testset "GlobalAlignment" begin
        affinegap = AffineGapScoreModel(
            match=0,
            mismatch=-6,
            gap_open=-5,
            gap_extend=-3
        )

        function testaln(alnstr)
            a, b, s, alnpair = alnscore(affinegap, alnstr)
            aln = pairalign(GlobalAlignment(), a, b, affinegap)
            @test score(aln) == s
            @test alignedpair(aln) == alnpair
            aln = pairalign(GlobalAlignment(), a, b, affinegap, score_only=true)
            @test score(aln) == s
        end

        @testset "empty sequences" begin
            aln = pairalign(GlobalAlignment(), "", "", affinegap)
            @test score(aln) == 0
        end

        @testset "complete match" begin
            testaln("""
            ACGT
            ACGT
            """)
        end

        @testset "mismatch" begin
            testaln("""
            ACGT
            AGGT
            """)

            testaln("""
            ACGT
            AGGA
            """)
        end

        @testset "insertion" begin
            testaln("""
            ACGTT
            ACGT-
            """)

            testaln("""
            ACGTTT
            ACGT--
            """)

            testaln("""
            ACCGT
            AC-GT
            """)

            testaln("""
            ACCCGT
            AC--GT
            """)

            testaln("""
            AACGT
            A-CGT
            """)

            testaln("""
            AAACGT
            A--CGT
            """)
        end

        @testset "deletion" begin
            testaln("""
            ACGT-
            ACGTT
            """)

            testaln("""
            ACGT-
            ACGTT
            """)

            testaln("""
            ACGT--
            ACGTTT
            """)

            testaln("""
            AC-GT
            ACCGT
            """)

            testaln("""
            AC--GT
            ACCCGT
            """)

            testaln("""
            A-CGT
            AACGT
            """)

            testaln("""
            A--CGT
            AAACGT
            """)
        end

        @testset "banded" begin
            a, b, s, alnpair = alnscore(affinegap, """
            ACGT
            ACGT
            """)
            aln = pairalign(GlobalAlignment(), a, b, affinegap, banded=true)
            @test score(aln) == s
            @test alignedpair(aln) == alnpair

            a, b, s, alnpair = alnscore(affinegap, """
            ACGT
            AGGT
            """)
            aln = pairalign(GlobalAlignment(), a, b, affinegap, banded=true)
            @test score(aln) == s
            @test alignedpair(aln) == alnpair

            a, b, s, alnpair = alnscore(affinegap, """
            ACG--T
            ACGAAT
            """)
            aln = pairalign(GlobalAlignment(), a, b, affinegap, banded=true, lower_offset=0, upper_offset=0)
            @test score(aln) == s
            @test alignedpair(aln) == alnpair
        end
    end

    @testset "SemiGlobalAlignment" begin
        affinegap = AffineGapScoreModel(
            match=0,
            mismatch=-6,
            gap_open=-5,
            gap_extend=-3
        )

        function testaln(alnstr)
            a, b, s, alnpair = alnscore(affinegap, alnstr, clip=false)
            aln = pairalign(SemiGlobalAlignment(), a, b, affinegap)
            @test score(aln) == s
            @test alignedpair(aln) == alnpair
            aln = pairalign(SemiGlobalAlignment(), a, b, affinegap, score_only=true)
            @test score(aln) == s
        end

        @testset "complete match" begin
            testaln("""
            ACGT
            ACGT
            """)
        end

        @testset "partial match" begin
            testaln("""
            --ACTT---
            TTACGTAGT
              ^^^^
            """)

            testaln("""
            --AC-TTG-
            TTACGTTGT
              ^^^^^^
            """)

            testaln("""
            --ACTAGT---
            TTAC--GTTGT
              ^^^^^^
            """)
        end
    end

    @testset "OverlapAlignment" begin
        affinegap = AffineGapScoreModel(
            match=3,
            mismatch=-6,
            gap_open=-5,
            gap_extend=-3
        )

        function testaln(alnstr)
            a, b, s, alnpair = alnscore(affinegap, alnstr, clip=false)
            aln = pairalign(OverlapAlignment(), a, b, affinegap)
            @test score(aln) == s
            @test alignedpair(aln) == alnpair
            aln = pairalign(OverlapAlignment(), a, b, affinegap, score_only=true)
            @test score(aln) == s
        end

        @testset "complete match" begin
            testaln("""
            ACGT
            ACGT
            """)
        end

        @testset "partial match" begin
            testaln("""
            ---ACGGTGATTAT
            GATACGGTGA----
               ^^^^^^^
            """)

            testaln("""
            ---AACGT-GATTAT
            GATAACGGAGA----
               ^^^^^^^^
            """)

            testaln("""
            GATACGGTGA----
            ---ACGGTGATTAT
               ^^^^^^^
            """)

            testaln("""
            GATAACGGAGA----
            ---AACGT-GATTAT
               ^^^^^^^^
            """)
        end
    end

    @testset "LocalAlignment" begin
        @testset "zero matching score" begin
            affinegap = AffineGapScoreModel(
                match=0,
                mismatch=-6,
                gap_open=-5,
                gap_extend=-3
            )

            function testaln(alnstr)
                a, b, s, alnpair = alnscore(affinegap, alnstr)
                aln = pairalign(LocalAlignment(), a, b, affinegap)
                @test score(aln) == s
                @test alignedpair(aln) == alnpair
                aln = pairalign(LocalAlignment(), a, b, affinegap, score_only=true)
                @test score(aln) == s
            end

            @testset "empty sequences" begin
                aln = pairalign(LocalAlignment(), "", "", affinegap)
                @test score(aln) == 0
            end

            @testset "complete match" begin
                testaln("""
                ACGT
                ACGT
                """)
            end

            @testset "partial match" begin
                testaln("""
                ACGT
                AGGT
                  ^^
                """)

                testaln("""
                   ACGT
                AACGTTT
                      ^
                """)
            end

            @testset "no match" begin
                a = "AA"
                b = "TTTT"
                aln = pairalign(LocalAlignment(), a, b, affinegap)
                @test score(aln) == 0
            end
        end

        @testset "positive matching score" begin
            affinegap = AffineGapScoreModel(
                match=5,
                mismatch=-6,
                gap_open=-5,
                gap_extend=-3
            )

            function testaln(alnstr)
                a, b, s, alnpair = alnscore(affinegap, alnstr)
                aln = pairalign(LocalAlignment(), a, b, affinegap)
                @test score(aln) == s
                @test alignedpair(aln) == alnpair
                aln = pairalign(LocalAlignment(), a, b, affinegap, score_only=true)
                @test score(aln) == s
            end

            @testset "complete match" begin
                testaln("""
                ACGT
                ACGT
                ^^^^
                """)
            end

            @testset "partial match" begin
                testaln("""
                ACGT
                AGGT
                  ^^
                """)
                testaln(" ACGT  \nAACGTTT\n ^^^^  \n")
                testaln("  AC-GT  \nAAACTGTTT\n")
            end

            @testset "no match" begin
                a = "AA"
                b = "TTTT"
                aln = pairalign(LocalAlignment(), a, b, affinegap)
                @test score(aln) == 0
            end
        end
    end

    @testset "EditDistance" begin
        mismatch = 1
        submat = DichotomousSubstitutionMatrix(0, mismatch)
        insertion = 1
        deletion = 2
        cost = CostModel(submat, insertion, deletion)

        function testaln(alnstr)
            a, b, dist = alndistance(cost, alnstr)
            aln = pairalign(EditDistance(), a, b, cost)
            @test distance(aln) == dist
            @test alignedpair(aln) == chomp(alnstr)
            aln = pairalign(EditDistance(), a, b, cost, distance_only=true)
            @test distance(aln) == dist
        end

        @testset "empty sequences" begin
            aln = pairalign(EditDistance(), "", "", cost)
            @test distance(aln) == 0
        end

        @testset "complete match" begin
            testaln("""
            ACGT
            ACGT
            """)
        end

        @testset "mismatch" begin
            testaln("""
            AGGT
            ACGT
            """)

            testaln("""
            AGGT
            ACGT
            """)
        end

        @testset "insertion" begin
            testaln("""
            ACGTT
            ACG-T
            """)

            testaln("""
            ACGTT
            -CG-T
            """)
        end

        @testset "deletion" begin
            testaln("""
            AC-T
            ACGT
            """)

            testaln("""
            -C-T
            ACGT
            """)
        end
    end

    @testset "LevenshteinDistance" begin
        @testset "empty sequences" begin
            aln = pairalign(LevenshteinDistance(), "", "")
            @test distance(aln) == 0
        end

        @testset "complete match" begin
            a = "ACGT"
            b = "ACGT"
            aln = pairalign(LevenshteinDistance(), a, b)
            @test distance(aln) == 0
        end
    end

    @testset "HammingDistance" begin
        function testaln(alnstr)
            a, b = split(chomp(alnstr), '\n')
            dist = sum([x != y for (x, y) in zip(a, b)])
            aln = pairalign(HammingDistance(), a, b)
            @test distance(aln) == dist
            @test alignedpair(aln) == chomp(alnstr)
            aln = pairalign(HammingDistance(), a, b, distance_only=true)
            @test distance(aln) == dist
        end

        @testset "empty sequences" begin
            aln = pairalign(HammingDistance(), "", "")
            @test distance(aln) == 0
        end

        @testset "complete match" begin
            testaln("""
            ACGT
            ACGT
            """)
        end

        @testset "mismatch" begin
            testaln("""
            ACGT
            AGGT
            """)

            testaln("""
            ACGT
            AGGA
            """)
        end

        @testset "indel" begin
            @test_throws Exception pairalign(HammingDistance(), "ACGT", "ACG")
            @test_throws Exception pairalign(HammingDistance(), "ACG", "ACGT")
        end
    end

    @testset "Print" begin
        seq1 = aa"EPVTSHPKAVSPTETKPTEKGQHLPVSAPPKITQSLKAEASKDIAKLTCAVESSALCA"
        seq2 = aa"EPSHPKAVSPTETKRCPTEKVQHLPVSAPPKITQFLKAEASKEIAKLTCVVESSVLRA"
        model = AffineGapScoreModel(BLOSUM62, gap_open=-10, gap_extend=-1)
        aln = alignment(pairalign(GlobalAlignment(), seq1, seq2, model))
        # julia 1.6+ uses shorter type aliases when printing types
        seqtype = VERSION >= v"1.6" ?
            "BioSequences.LongAminoAcidSeq" :
            "BioSequences.LongSequence{BioSequences.AminoAcidAlphabet}"
        buf = IOBuffer()
        show(buf, MIME"text/plain"(), aln)
        @test String(take!(buf)) ==
        """
        PairwiseAlignment{$(seqtype),$(VERSION >= v"1.6" ? " " : "")$(seqtype)}:
          seq:  1 EPVTSHPKAVSPTETK--PTEKGQHLPVSAPPKITQSLKAEASKDIAKLTCAVESSALCA 58
                  ||  ||||||||||||  |||| ||||||||||||| ||||||| |||||| |||| | |
          ref:  1 EP--SHPKAVSPTETKRCPTEKVQHLPVSAPPKITQFLKAEASKEIAKLTCVVESSVLRA 58
        """
        @test sprint(print, aln) ==
        """
          seq:  1 EPVTSHPKAVSPTETK--PTEKGQHLPVSAPPKITQSLKAEASKDIAKLTCAVESSALCA 58
                  ||  ||||||||||||  |||| ||||||||||||| ||||||| |||||| |||| | |
          ref:  1 EP--SHPKAVSPTETKRCPTEKVQHLPVSAPPKITQFLKAEASKEIAKLTCVVESSVLRA 58
        """
        buf = IOBuffer()
        BioAlignments.print_pairwise_alignment(buf, aln, width=50)
        @test String(take!(buf)) ==
        """
          seq:  1 EPVTSHPKAVSPTETK--PTEKGQHLPVSAPPKITQSLKAEASKDIAKLT 48
                  ||  ||||||||||||  |||| ||||||||||||| ||||||| |||||
          ref:  1 EP--SHPKAVSPTETKRCPTEKVQHLPVSAPPKITQFLKAEASKEIAKLT 48

          seq: 49 CAVESSALCA 58
                  | |||| | |
          ref: 49 CVVESSVLRA 58
        """
        buf = IOBuffer()
        print(buf, (aln,))
        @test String(take!(buf)) == (
        	"""(PairwiseAlignment{$seqtype,$(VERSION >= v"1.6" ? " " : "")$(seqtype)}""" *
        	"""(lengths=(58, 58)/60),)"""
        )
        # Result from EMBOSS Needle:
        # EMBOSS_001         1 EPVTSHPKAVSPTETK--PTEKGQHLPVSAPPKITQSLKAEASKDIAKLT     48
        #                      ||  ||||||||||||  ||||.|||||||||||||.|||||||:|||||
        # EMBOSS_001         1 EP--SHPKAVSPTETKRCPTEKVQHLPVSAPPKITQFLKAEASKEIAKLT     48
        #
        # EMBOSS_001        49 CAVESSALCA     58
        #                      |.||||.|.|
        # EMBOSS_001        49 CVVESSVLRA     58
    end
end
