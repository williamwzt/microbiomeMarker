#' Statistical test between two groups
#'
#' @param ps a [`phyloseq::phyloseq-class`] object
#' @param group character, the variable to set the group
#' @param rank_name character, taxonomic names of [`phyloseq::phyloseq-class`]
#' to compare
#' @param method test method, must be one of "welch.test", "t.test" or
#' "white.test"
#' @param p_adjust method for multiple test correction, default `none`,
#' for more details see [stats::p.adjust].
#' @param p_value_cutoff numeric, p value cutoff, default 0.05
#' @param diff_mean_cutoff,ratio_proportion_cutoff cutoff of different mean
#' proportions and ratio proportions, default `NULL` which means no effect size
#' filter.
#' @param conf_level numeric, confidence level of interval,
#' @param nperm interger, number of permutations for white non parametric t test
#'  estimation
#' @param ... extra arguments passed to [t.test()] or [fisher.test()]
#' @importFrom phyloseq rank_names tax_glom
#' @importFrom dplyr select everything filter
#' @export
#' @author Yang Cao
test_two_groups <- function(ps,
                           group,
                           rank_name,
                           method = c("welch.test", "t.test", "white.test"),
                           p_adjust = c("none", "fdr", "bonferroni", "holm",
                                        "hochberg", "hommel", "BH", "BY"),
                           p_value_cutoff = 0.05,
                           diff_mean_cutoff = NULL,
                           ratio_proportion_cutoff = NULL,
                           conf_level = 0.95,
                           nperm = 1000,
                           ...) {
  stopifnot(inherits(ps, "phyloseq"))

  p_adjust <- match.arg(
    p_adjust,
    c("none", "fdr", "bonferroni", "holm", "hochberg", "hommel", "BH", "BY")
  )
  method <- match.arg(method, c("welch.test", "t.test", "white.test"))

  ranks <- rank_names(ps)
  if (!rank_name %in% ranks) {
    stop("`rank_name` must be one of availabel taxonomic ranks of `ps`")
  }

  # agglomerate tax in the same rank_name
  if (rank_name != ranks[length(ranks)]) {
    ps <- tax_glom(ps, taxrank = rank_name)
  }
  abd <- otu_table(ps) %>%
    t() %>%
    as.data.frame()

  # relative abundance
  abd_sum <- rowSums(abd)
  abd_prop <- sweep(abd, 1, abd_sum, "/")

  sample_meta <- sample_data(ps)
  if (!group %in% names(sample_meta)) {
    stop("`group` must in the field of sample meta data")
  }
  groups <- sample_meta[[group]]
  abd_prop_group <- split(abd_prop, groups)

  # used for permute statistic in white's non parametric t test method
  orig_abd_group <- split(abd, groups)

  if (method == "welch.test") {
    test_res <- run_t_test(abd_prop_group, conf_level = conf_level, ...)
  } else if (method == "t.test") {
    test_res <- run_t_test(abd_prop_group, conf_level, var_equal = TRUE, ...)
  } else if (method == "white.test") {
    test_res <- run_white_test(
      abd_prop_group[[1]],
      abd_prop_group[[2]],
      orig_abd_group[[1]],
      orig_abd_group[[2]],
      group_names = names(abd_prop_group),
      conf_level = conf_level,
      nperm = nperm,
      ...
    )
  }

  feature <- tax_table(ps)[, rank_name] %>% unclass()
  test_res$feature <- feature[, 1]

  # ratio proportion
  rp <- purrr::pmap_dbl(abd_prop_group, ~ calc_ratio_proportion(.x, .y))
  test_res$ratio_proportion <- rp

  # set the ci and ratio proportion to 0, if both of the mean is 0
  test_res <- mutate(
    test_res,
    ci_lower = ifelse(.data$pvalue == 1, 0, .data$ci_lower),
    ci_upper = ifelse(.data$pvalue == 1, 0, .data$ci_upper)) %>%
    select(.data$feature, everything())

  # p value correction for multiple comparisons
  test_res$pvalue_corrected <- p.adjust(test_res$pvalue, method = p_adjust)

  # p <= 0.05
  test_filtered <-  filter(test_res, .data$pvalue_corrected <= p_value_cutoff)
  # abs(diff_mean) >= cutoff
  if (!is.null(diff_mean_cutoff)) {
    test_filtered <- filter(
      test_filtered,
      abs(.data$diff_mean) >= diff_mean_cutoff
    )
  }
  # ratio proportion >= cutoff or <= 1/cutoff
  if (!is.null(ratio_proportion_cutoff)) {
    test_filtered <- filter(
      test_filtered,
      .data$ratio_proportion >= ratio_proportion_cutoff | .data$ratio_proportion <= 1/ratio_proportion_cutoff
    )
  }

  if (nrow(test_filtered) == 0) {
    warning("No significant features were found, return all the features")
    marker <- microbiomeMarker(
      marker_table(test_res),
      otu_table(t(abd), taxa_are_rows = TRUE),
      tax_table(ps)
    )
  } else {
    marker <- microbiomeMarker(
      marker_table(test_filtered),
      otu_table(t(abd), taxa_are_rows = TRUE),
      tax_table(ps)
    )
  }

  marker
}

# t test and welch test ---------------------------------------------------

#' run t test or welch test
#'
#' @param abd_group a two length list, each element represents the feature
#' abundance of a group
#' @param conf_level numeric, confidence level of the interval, default 0.95
#' @param var_equal a logical variable indicating whether to treat the two
#' variances as being equal. If TRUE then the pooled variance is used to
#' estimate the variance otherwise the Welch (or Satterthwaite) approximation
#' to the degrees of freedom is used.
#' @param ... extra arguments passed to [t.test()]
#' @seealso [stats::t.test()]
#' @noRd
run_t_test <- function(abd_group, conf_level = 0.95, var_equal = FALSE, ...) {
  if (length(abd_group) != 2) {
    stop("welch test requires test between two groups")
  }

  t_res <- purrr::pmap(
    abd_group,
    ~ t.test(.x, .y, conf.level = conf_level, var.equal = var_equal, ...)
  )

  # p value
  p <- purrr::map_dbl(t_res, ~ .x$p.value)
  # set the p value to 1 is the result is NA
  p[is.na(p)] <- 1

  # mean proportion of each group
  # different between means
  t_estimate <- purrr::map(t_res, ~ .x$estimate)
  mean_g1 <- purrr::map_dbl(t_estimate, ~ .x[1])
  mean_g2 <- purrr::map_dbl(t_estimate, ~ .x[2])
  diff_means <- mean_g1 - mean_g2

  # confidence interval
  ci <- purrr::map(t_res, ~ .x$conf.int)
  ci_lower <- purrr::map_dbl(ci, ~ .x[1])
  ci_upper <- purrr::map_dbl(ci, ~ .x[2])

  group_names <- names(abd_group)
  mean_names <- paste(group_names, "mean_rel_freq", sep = "_")
  res <- data.frame(
    p,
    mean_g1*100,
    mean_g2*100,
    diff_means*100,
    ci_lower*100,
    ci_upper*100
  )
  names(res) <- c("pvalue", mean_names, "diff_mean", "ci_lower", "ci_upper")

  res
}

# white's non parametric t test -------------------------------------------

#' White's non-parametric t-test
#' @param prop_group1,prop_group2 a `data.frame`, relative abundance of group 1
#' and group 2
#' @param orig_group1,orig_group2 a `data.frame`, absolute abudnace of group 1
#' and group 2
#' @param group_names character vector, group names
#' @param conf_level numeric, confidence level of the interval, default 0.95
#' @param nperm number of permutations, default 1000
#' @param ... extra arguments passed to [t.test()]
#' @noRd
run_white_test <- function(prop_group1,
                           prop_group2,
                           orig_group1,
                           orig_group2,
                           group_names,
                           conf_level = 0.95,
                           nperm = 1000,
                           ...) {

  two_sample_ts <- calc_twosample_ts(prop_group1, prop_group2)
  t_statistic <- purrr::map_dbl(two_sample_ts, ~ .x["t_static"])
  diff_means <- purrr::map_dbl(two_sample_ts, ~ .x["diff_means"])

  permute_p <- calc_permute_p(
    prop_group1, prop_group2,
    orig_group1, orig_group2,
    t_statistic,
    conf_level = conf_level,
    nperm = nperm
  )

  bootstrap_ci <- calc_bootstrap_ci(
    prop_group1,
    prop_group2,
    conf_level = conf_level,
    replicates = nperm
  )

  # sparse feature ------------------------------------------------------------
  n1 <- nrow(orig_group1)
  n2 <- nrow(orig_group2)
  sparse_index1 <- purrr::map_dbl(orig_group1, sum) < n1
  sparse_index2 <- purrr::map_dbl(orig_group2, sum) < n2
  sparse_index <- which(sparse_index1 & sparse_index2)

  sparse_res <- calc_sparse_p(orig_group1, orig_group2, sparse_index, ...)
  # p value
  sparse_p <- purrr::map_dbl(sparse_res, ~ .x$p.value)
  # set the p value to 1 is the result is NA
  sparse_p[is.na(sparse_p)] <- 1

  # mean proportion of each group
  sparse_diff_means <- calc_sparse_diff_mean(orig_group1, orig_group2, sparse_index)

  # confidence interval
  sparse_ci <- purrr::map(sparse_res, ~ .x$conf.int)
  sparse_ci_lower <- purrr::map_dbl(sparse_ci, ~ .x[1])
  sparse_ci_upper <- purrr::map_dbl(sparse_ci, ~ .x[2])

  permute_p$pvalue_two_side[sparse_index] <- sparse_p
  diff_means[sparse_index] <- sparse_diff_means
  ci_lower <- bootstrap_ci$ci_lower
  ci_lower[sparse_index] <- sparse_ci_lower
  ci_upper <- bootstrap_ci$ci_upper
  ci_upper[sparse_index] <- sparse_ci_upper

  mean_g1 <- colMeans(prop_group1)
  mean_g2 <- colMeans(prop_group2)

  mean_names <- paste(group_names, "mean_rel_freq", sep = "_")
  res <- data.frame(
    permute_p$pvalue_two_side,
    mean_g1*100,
    mean_g2*100,
    diff_means*100,
    ci_lower*100,
    ci_upper*100
  )
  names(res) <- c("pvalue", mean_names, "diff_mean", "ci_lower", "ci_upper")

  res
}

#' permuted p values from Storey and Tibshirani(2003)
#'
#' @param t_statistic white non parametric t statistic
#' @noRd
calc_permute_p <- function(prop_group1,
                           prop_group2,
                           orig_group1,
                           orig_group2,
                           t_statistic,
                           conf_level = 0.95,
                           nperm = 1000) {
  n1 <- nrow(prop_group1)
  n2 <- nrow(prop_group2)
  smaples_n <- n1 + n2
  features_n <- length(prop_group1)


  # calculate p value -------------------------------------------------------
  permuted_res <- purrr::rerun(nperm, calc_permute_ts(prop_group1, prop_group2))
  permuted_ts <- purrr::map_df(
    permuted_res,
    ~ .x %>% purrr::map(~ .x["t_static"])
  )
  permuted_diff_means<- purrr::map_df(
    permuted_res,
    ~ .x %>% purrr::map(~ .x["diff_means"])
  )

  if (n1 < 8 || n2 < 8) {
    # pool just the frequently observed ts
    cleaned_permuted_ttests <- permuted_ts
    group1_high_freq <- colSums(orig_group1) >= n1
    group2_high_freq <- colSums(orig_group2) >= n2
    high_freq_indices <- which(group1_high_freq | group2_high_freq)

    pvalue_one_side <- rep(0, features_n)
    pvalue_two_side <- rep(0, features_n)

    for (hf_index in high_freq_indices) {
      one_side <- 0
      two_side <- 0

      for (i in 1:nperm) {
        for (hf_index2 in high_freq_indices) {
          # one side
          if (cleaned_permuted_ttests[i, hf_index2] > t_statistic[hf_index]) {
            one_side <- one_side + 1
          }

          # two side
          if (abs(cleaned_permuted_ttests[i, hf_index2]) > abs(t_statistic[hf_index])) {
            two_side <- two_side + 1
          }
        }
      }

      pvalue_one_side[hf_index] <- 1/(nperm*length(high_freq_indices))*one_side
      pvalue_two_side[hf_index] <- 1/(nperm*length(high_freq_indices))*two_side
    }

  } else {
    no <- calc_p_large_sample(permuted_ts, t_statistic)
    two_side_no <- purrr::map_dbl(no, ~ .x["two_side"])
    g_side_no <- purrr::map_dbl(no, ~ .x["g_side"])
    l_side_no <- purrr::map_dbl(no, ~ .x["l_side"])

    pvalue_two_side <- 1/(nperm + 1) * (two_side_no + 1)
    pvalue_g_side <- 1/(nperm + 1) * (g_side_no + 1)
    pvalue_l_side <- 1/(nperm + 1) * (l_side_no + 1)
  }

  pvalue <- data.frame(
    pvalue_two_side = pvalue_two_side,
    pvalue_g_side = pvalue_g_side,
    pvalue_l_side = pvalue_l_side
  )

  pvalue
}

# calculate the permute p value, if number of samples in both groups are larger
# than 8
calc_p_large_sample <- function(permuted_ts, t_statistic) {
  no <- purrr::map2(
    permuted_ts,
    t_statistic,
    ~ purrr::map_df(
      .x,
      function(i) {
        l_side <- 0
        g_side <- 0
        two_side <- 0
        if (i > .y) {
          g_side <- g_side + 1
        }
        if (i < .y) {
          l_side <- l_side + 1
        }
        if (abs(i) > abs(.y)) {
          two_side <- two_side + 1
        }
        return(c(two_side = two_side, g_side = g_side, l_side = l_side))
      }
    )
  )

  purrr::map(no, colSums)
}

# bootstrap confidence interval
calc_bootstrap_ci <- function(prop_group1,
                              prop_group2,
                              conf_level = 0.95,
                              replicates = 1000) {
  diff_means <- purrr::map2_df(
    prop_group1,
    prop_group2,
    bootstrap_diff_mean_prop_single
  )

  ci_lower <- purrr::map_dbl(
    diff_means,
    ~ .x[max(0, floor(0.5*(1-conf_level)*length(.x)))]
  )

  ci_upper <- purrr::map_dbl(
    diff_means,
    ~ .x[min(length(.x) - 1,
             ceiling((conf_level + 0.5*(1.0 - conf_level))*length(.x)))
        ]
  )

  return(data.frame(ci_lower = ci_lower, ci_upper = ci_upper))
}

# bootstrap one time, difference mean proportion of an single feature
bootstrap_diff_mean_prop_single <- function(group1, group2, replicates = 1000) {
  bootstrap_one <- function(group1, group2) {
    n1 <- length(group1)
    n2 <- length(group2)
    choices1 <- sample.int(n1, n1, replace = TRUE)
    choices2 <- sample.int(n2, n2, replace = TRUE)
    sample_group1 <- group1[choices1]
    sample_group2 <- group2[choices2]
    diff_means <- mean(sample_group1) - mean(sample_group2)

    diff_means
  }

  diff_means <- replicate(
    replicates,
    bootstrap_one(group1, group2),
    simplify = TRUE
  )

  return(sort(diff_means))
}

calc_permute_ts <- function(prop_group1, prop_group2) {
   n1 <- nrow(prop_group1)
   n2 <- nrow(prop_group2)
   samples_n <- n1 + n2
   perm <- sample.int(samples_n, samples_n)
   features_n <- length(prop_group1)

   # permute the rows
   prop_group <- dplyr::bind_rows(prop_group1, prop_group2)
   prop_group_permute <- prop_group[perm, ]

   calc_twosample_ts(
     prop_group_permute[1:n1, ],
     prop_group_permute[(n1 + 1):(n1 + n2), ]
   )
}

# Calculate two sample t statistic of all features
calc_twosample_ts <- function(prop_group1, prop_group2) {
  ts <- purrr::map2(
    prop_group1,
    prop_group2,
    calc_twosample_ts_single_feature
  )

  ts
}

#' Calculate two sample t statistic of a feature, return a two length vector:
#' two sample t static and difference means (effect size)
#' @importFrom stats var
#' @noRd
calc_twosample_ts_single_feature <- function(prop_group1, prop_group2) {
  n1 <- length(prop_group1)
  n2 <- length(prop_group2)

  mean_g1 <- sum(prop_group1)/n1
  var_g1 <- var(prop_group1)
  stderr_g1 <- var_g1/n1

  mean_g2 <- sum(prop_group2)/n2
  var_g2 <- var(prop_group2)
  stderr_g2 <- var_g2/n2

  diff_means <- mean_g1 - mean_g2

  denom <- sqrt(stderr_g1 + stderr_g2)
  if (denom == 0) {
    warning('degenerate case: zero variance for both groups; variance set to 1e-6.')
    t_static <- diff_means/1e-6
  } else {
    t_static <- diff_means/denom
  }

  return(c(t_static = t_static, diff_means = diff_means))
}

#' calculate p values for sparse data using fisher's exact test
#' @importFrom stats fisher.test
#' @noRd
calc_sparse_p <- function(orig_group1, orig_group2, sparse_index, ...) {
  cm_list <- create_contingency_matrix(
    orig_group1,
    orig_group2,
    sparse_index = sparse_index
  )

  purrr::map(cm_list, fisher.test, ...)
}

# create contingency matrix  list for fisher exact test
create_contingency_matrix <- function(orig_group1, orig_group2, sparse_index) {
  all1 <- sum(orig_group1)
  all2 <- sum(orig_group2)
  sparse_group1 <- orig_group1[sparse_index]
  sparse_group2 <- orig_group2[sparse_index]
  feature_abd1 <- colSums(sparse_group1)
  feature_abd2 <- colSums(sparse_group2)

  cm_list <- purrr::map2(
    feature_abd1, feature_abd2,
    ~ matrix(
      c(.x, all1 - .x, .y, all2 - .y),
      nrow = 2,
      dimnames = list(c("featrue", "other"), c("group1", "group2"))
    )
  )

  cm_list
}

calc_sparse_diff_mean <- function(orig_group1, orig_group2, sparse_index) {
  all1 <- sum(orig_group1)
  all2 <- sum(orig_group2)
  sparse_group1 <- orig_group1[sparse_index]
  sparse_group2 <- orig_group2[sparse_index]
  feature_abd1 <- colSums(sparse_group1)
  feature_abd2 <- colSums(sparse_group2)

  purrr::map2_dbl(
    feature_abd1,
    feature_abd2,
    ~ (.x/all1 - .y/all2)
  )
}


# ratio proportion --------------------------------------------------------

#' ratio proportion used for effect size
#'
#' @param abd1,abd2 numeric vector, abundance of a given feature of the group1
#' and group2
#' @param pseducount numeric, pseducount for unobserved data
#'
#' @return numeric ratio proportion for a feature
#' @noRd
calc_ratio_proportion <- function(abd1, abd2, pseudocount = 0.5) {
  n1 <- length(abd1)
  n2 <- length(abd2)

  mean_g1 <- sum(abd1)/n1
  mean_g2 <- sum(abd2)/n2

  if (mean_g1 == 0 || mean_g2 == 0) {
    pseudocount <- pseudocount/(mean_g1 + mean_g2)
    mean_g1 <- mean_g1 + pseudocount
    mean_g2 <- mean_g2 + pseudocount
  }

  res <- mean_g1/mean_g2
  if (is.na(res)) {
    res <- 0
  }

  res
}
