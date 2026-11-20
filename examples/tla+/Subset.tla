---- MODULE Subset ----
\* 常量转变量：CompleteCollection 固定，Subset 从它的非空子集里枚举
EXTENDS Integers, FiniteSets

VARIABLES Subset
CONSTANTS CompleteCollection

Init ≜ Subset ∈ (SUBSET CompleteCollection) \ {{}}

Next ≜ UNCHANGED Subset

Spec ≜ Init ∧ □[Next]_Subset

\* 不管 Init 挑到哪个子集，这两条都成立
IsSubset ≜ Subset ⊆ CompleteCollection ∧ Subset ≠ {}
====
