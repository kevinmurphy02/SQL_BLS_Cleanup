# SQL_BLS_Cleanup

This project is a small real world data-engineering style pipeline built in SQL. I start from raw text files from the U.S. Bureau of Labor Statistics (BLS) for the Consumer Price Index (CPI) and turn them into clean, analysis-ready tables and views.
The goal was to show SQL skills around:
  * importing messy real data
  * data cleaning and validation
  * basic data modeling (fact + dimension tables)
  * using window functions for time-series analysis


All raw files come from the official BLS CPI time.series “cu” group:
https://download.bls.gov/pub/time.series/cu/
