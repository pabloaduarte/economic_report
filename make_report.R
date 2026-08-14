# =============================================================
#  make_report.R
#  Orchestrator for the Konjunkturbericht (PDF & HTML)
#  Supports 4 Languages: DE, EN, ES, IT
# =============================================================

.libPaths(c("~/R/library", .libPaths()))

# Auto-install missing R dependencies for Quarto orchestration
required_pkgs <- c("quarto", "crayon", "jsonlite", "dplyr", "zoo", "xts")
missing_pkgs <- required_pkgs[!(required_pkgs %in% installed.packages()[, "Package"])]
if (length(missing_pkgs) > 0) {
  cat("Installing missing packages:", paste(missing_pkgs, collapse = ", "), "\n")
  install.packages(missing_pkgs, repos = "https://cloud.r-project.org")
}

suppressPackageStartupMessages(library(quarto))

# 1. Parse Command & Language
# Usage: Rscript make_report.R [task] [lang]
# Example: Rscript make_report.R all es
args <- commandArgs(trailingOnly = TRUE)
cmd  <- if (length(args) > 0) args[1] else "all"

# 2. Configuration & Automation
SUPPORTED_LANGS <- c("de", "en", "es", "it")
# If a second argument is provided and is a valid lang, use it; otherwise use all.
LANGUAGES <- if (length(args) > 1 && tolower(args[2]) %in% SUPPORTED_LANGS) tolower(args[2]) else SUPPORTED_LANGS

OUTPUT_DIR <- "output"
dir.create(OUTPUT_DIR, showWarnings = FALSE)

# Derive report date from system date (Automated)
MONTH_NAMES_DE <- c("Januar", "Februar", "Maerz", "April", "Mai", "Juni", 
                    "Juli", "August", "September", "Oktober", "November", "Dezember")
REPORT_MONTH   <- MONTH_NAMES_DE[as.integer(format(Sys.Date(), "%m"))]
REPORT_YEAR    <- format(Sys.Date(), "%Y")

# Logic Flags
DO_DATA   <- cmd %in% c("all", "data")
DO_CHARTS <- cmd %in% c("all", "charts")
DO_PDF    <- cmd %in% c("all", "pdf", "reports")
DO_HTML   <- cmd %in% c("all", "html", "reports")

# --- PHASE 1: DATA FETCHING ---
if (DO_DATA) {
  cat("\n[STEP 1] Fetching latest data (Macrobond & Polymarket)...\n")
  # Note: Requires Macrobond API license on the machine
  system("Rscript fetch_macrobond.R")
  
  cat("\n[STEP 1b] Exporting Excel data file...\n")
  system("Rscript export_data.R")
}

# --- PHASE 2: CHART GENERATION ---
if (DO_CHARTS) {
  cat("\n[STEP 2] Generating high-res charts (SVG/PDF/PNG) for all languages...\n")
  for (l in LANGUAGES) {
    cat(sprintf("  -> Creating %s charts...\n", toupper(l)))
    # We use the smart runner, so this will be fast for unchanged data
    system(sprintf("Rscript charts_macrobond.R %s", l))
  }
}

# --- PHASE 3: PDF REPORTS (BEAMER) ---
if (DO_PDF) {
  cat("\n[STEP 3] Rendering PDF reports (BEAMER)...\n")
  for (l in LANGUAGES) {
    cat(sprintf("  -> Rendering %s PDF report...\n", toupper(l)))
    
    # Map to the new _final naming convention
    input_qmd <- sprintf("konjunkturbericht_final_%s.qmd", l)
    if (l == "de") input_qmd <- "konjunkturbericht_final.qmd" # German is the master
    
    if (!file.exists(input_qmd)) {
      cat(sprintf("     [SKIP] File not found: %s\n", input_qmd))
      next
    }
    
    out_name <- sprintf("Konjunkturbericht_%s_%s_%s.pdf", REPORT_MONTH, REPORT_YEAR, toupper(l))
    
    tryCatch({
      cat(sprintf("     Running Quarto render for %s...\n", input_qmd))
      quarto_render(input = input_qmd, output_format = "beamer", quiet = FALSE)
      
      # Determine expected output name
      rendered_pdf <- gsub("\\.qmd$", ".pdf", input_qmd)
      
      if (file.exists(rendered_pdf)) {
        # 1. Store in output/ with full date for archiving
        file.copy(rendered_pdf, file.path(OUTPUT_DIR, out_name), overwrite = TRUE)
        
        # 2. Store in docs/ with simple name for HTML download link
        web_pdf_name <- sprintf("Konjunkturbericht_%s.pdf", l)
        dir.create("docs", showWarnings = FALSE)
        docs_pdf_path <- file.path("docs", web_pdf_name)
        file.copy(rendered_pdf, docs_pdf_path, overwrite = TRUE)
        
        # 3. Compress the web version in docs/ using ps2pdf if available
        cat("     Compressing web version for docs/...\n")
        temp_pdf <- tempfile(fileext = ".pdf")
        cmd_str <- sprintf("ps2pdf -dPDFSETTINGS=/ebook %s %s", shQuote(docs_pdf_path), shQuote(temp_pdf))
        status <- system(cmd_str)
        if (status == 0 && file.exists(temp_pdf) && file.info(temp_pdf)$size > 0) {
          file.copy(temp_pdf, docs_pdf_path, overwrite = TRUE)
          file.remove(temp_pdf)
          cat(sprintf("     Success: Compressed %s\n", web_pdf_name))
        } else {
          cat(sprintf("     Warning: Compression failed or returned empty file for %s\n", web_pdf_name))
          if (file.exists(temp_pdf)) file.remove(temp_pdf)
        }
        
        file.remove(rendered_pdf)
        cat(sprintf("     Success: %s (Archived and Web-ready)\n", out_name))
      } else {
        cat(sprintf("     Warning: Expected %s not found. Checking directory...\n", rendered_pdf))
        pdfs <- list.files(pattern = "\\.pdf$")
        if (length(pdfs) > 0) cat("     Available PDFs:", paste(pdfs, collapse=", "), "\n")
      }
    }, error = function(e) {
      cat(sprintf("     ERROR rendering %s: %s\n", l, e$message))
    })
  }
}

# --- PHASE 4: HTML REPORTS (Interactive) ---
if (DO_HTML) {
  cat("\n[STEP 4] Rendering Interactive HTML reports using Quarto Profiles...\n")
  
  for (l in LANGUAGES) {
    cat(sprintf("  -> Rendering %s HTML reports...\n", toupper(l)))
    
    input_qmd <- sprintf("konjunkturbericht-html_%s.qmd", l)
    if (l == "de") input_qmd <- "konjunkturbericht-html_de.qmd"
    
    if (!file.exists(input_qmd)) {
      cat(sprintf("     [SKIP] File not found: %s\n", input_qmd))
      next
    }
    
    # Target 1: Internal Version (Profile 'internal') -> output/
    tryCatch({
      cat(sprintf("     -> Generating 'Internal' version (Self-Contained)...\n"))
      quarto_render(input = input_qmd, profile = "internal", quiet = TRUE)
      
      # Rename to final archival name
      rendered_base <- gsub("\\.qmd$", ".html", input_qmd)
      rendered_path <- file.path("output", rendered_base)
      archival_name <- sprintf("Konjunkturbericht_%s_%s_%s.html", REPORT_MONTH, REPORT_YEAR, toupper(l))
      
      if (file.exists(rendered_path)) {
        file.rename(rendered_path, file.path("output", archival_name))
        cat(sprintf("     Success (Internal): %s\n", archival_name))
      }
    }, error = function(e) {
      cat(sprintf("     Error rendering %s Internal HTML: %s\n", l, e$message))
    })

    # Target 2: Web Version (Profile 'github') -> docs/
    tryCatch({
      cat(sprintf("     -> Generating 'GitHub' version (Lightweight)...\n"))
      quarto_render(input = input_qmd, profile = "github", quiet = TRUE)
      
      # Determine final web name
      rendered_base <- gsub("\\.qmd$", ".html", input_qmd)
      rendered_path <- file.path("docs", rendered_base)
      web_name      <- if (l == "en") "index.html" else paste0(l, ".html")
      
      if (file.exists(rendered_path)) {
        file.rename(rendered_path, file.path("docs", web_name))
        cat(sprintf("     Success (Website): docs/%s\n", web_name))
      }
    }, error = function(e) {
      cat(sprintf("     Error rendering %s Website HTML: %s\n", l, e$message))
    })
  }
}

# --- PHASE 5: STANDALONE PDF COMPRESSION ---
if (cmd == "compress") {
  cat("\n[STANDALONE] Compressing web PDF versions (docs/)...\n")
  for (l in LANGUAGES) {
    web_pdf_name <- sprintf("Konjunkturbericht_%s.pdf", l)
    docs_pdf_path <- file.path("docs", web_pdf_name)
    
    # Look for source in output/ or root
    out_name <- sprintf("Konjunkturbericht_%s_%s_%s.pdf", REPORT_MONTH, REPORT_YEAR, toupper(l))
    archive_path <- file.path(OUTPUT_DIR, out_name)
    
    input_qmd <- sprintf("konjunkturbericht_final_%s.qmd", l)
    if (l == "de") input_qmd <- "konjunkturbericht_final.qmd"
    rendered_pdf <- gsub("\\.qmd$", ".pdf", input_qmd)
    
    source_pdf <- NULL
    if (file.exists(rendered_pdf)) {
      source_pdf <- rendered_pdf
    } else if (file.exists(archive_path)) {
      source_pdf <- archive_path
    }
    
    if (is.null(source_pdf)) {
      cat(sprintf("     [SKIP] Source PDF not found for language %s (checked %s and %s)\n", 
                  toupper(l), rendered_pdf, archive_path))
      next
    }
    
    dir.create("docs", showWarnings = FALSE)
    file.copy(source_pdf, docs_pdf_path, overwrite = TRUE)
    
    cat(sprintf("     Compressing docs/%s...\n", web_pdf_name))
    temp_pdf <- tempfile(fileext = ".pdf")
    cmd_str <- sprintf("gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.5 -dPDFSETTINGS=/prepress -dNOPAUSE -dQUIET -dBATCH -sOutputFile=%s %s", shQuote(temp_pdf), shQuote(docs_pdf_path))
    status <- system(cmd_str)
    if (status == 0 && file.exists(temp_pdf) && file.info(temp_pdf)$size > 0) {
      file.copy(temp_pdf, docs_pdf_path, overwrite = TRUE)
      file.remove(temp_pdf)
      cat(sprintf("     Success: Compressed docs/%s\n", web_pdf_name))
    } else {
      cat(sprintf("     Warning: Compression failed or returned empty file for docs/%s\n", web_pdf_name))
      if (file.exists(temp_pdf)) file.remove(temp_pdf)
    }
  }
}

cat("\n=== ALL OPERATIONS COMPLETE! ===\n")
cat("Reports are generated in the 'output/' and 'docs/' directories.\n", sep="")
