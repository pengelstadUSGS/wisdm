## ---------------------------
## wisdm - variable reduction
## ApexRMS, August 2022
## ---------------------------

# built under R version 4.1.3 & SyncroSim version 2.4.0
# Script pulls in site-specific covariate data; calls shiny widget to display 
# interactive correlation tool; saves reduced dataset of user selected covariates

# source dependencies ----------------------------------------------------------

library(rsyncrosim)
library(tidyr)
library(dplyr)
library(shiny)

packageDir <- Sys.getenv("ssim_package_directory")
source(file.path(packageDir, "04-variable-reduction-functions.R"))

# Connect to library -----------------------------------------------------------

# Active project and scenario
myProject <- rsyncrosim::project()
myScenario <- scenario()

# path to ssim directories
ssimTempDir <- ssimEnvironment()$TransferDirectory 

# Read in datasheets
covariatesSheet <- datasheet(myProject, "wisdm_Covariates", optional = T, includeKey = T)
fieldDataSheet <- datasheet(myScenario, "wisdm_FieldData", optional = T)
siteDataSheet <- datasheet(myScenario, "wisdm_SiteData", lookupsAsFactors = F)
covariateSelectionSheet <- datasheet(myScenario, "wisdm_CovariateSelectionOptions", optional = T)
covariateCorrelationSheet <- datasheet(myScenario, "wisdm_CovariateCorrelationMatrix", optional = T)


# Set defaults -----------------------------------------------------------------

## Covariate selection 
if(nrow(covariateSelectionSheet)<1){
  covariateSelectionSheet <- addRow(covariateSelectionSheet, list(DisplayHighestCorrelations = TRUE,
                                                                  CorrelationThreshold = 0.7, 
                                                                  NumberOfPlots = 5))
}
if(is.na(covariateSelectionSheet$DisplayHighestCorrelations)){covariateSelectionSheet$DisplayHighestCorrelations <- TRUE}
if(is.na(covariateSelectionSheet$CorrelationThreshold)){covariateSelectionSheet$CorrelationThreshold <- 0.7}
if(is.na(covariateSelectionSheet$NumberOfPlots)){covariateSelectionSheet$NumberOfPlots <- 5}

saveDatasheet(myScenario, covariateSelectionSheet, "wisdm_CovariateSelectionOptions")

# Prep inputs ------------------------------------------------------------------

# merge field and site data
siteDataWide <- spread(siteDataSheet, key = CovariatesID, value = "Value")
siteDataWide <- merge(fieldDataSheet, siteDataWide, by = "SiteID")
siteData <- select(siteDataWide, -c(SiteID, X, Y, UseInModelEvaluation, ModelSelectionSplit, Weight)) # 

# identify categorical covariates and drop any with a single level
if(sum(covariatesSheet$IsCategorical, na.rm = T)>0){
  factorVars <- covariatesSheet$CovariateName[which(covariatesSheet$IsCategorical == T & covariatesSheet$CovariateName %in% names(siteData))]
  if(length(factorVars)>0){
    badFactors <- NULL
    for (i in 1:length(factorVars)){
      factor.table <- table(siteData[,factorVars[i]])
      if(length(factor.table)<2){ badFactors <- c(badFactors, factorVars[i]) }
    }
    if(length(badFactors) > 0){
      factorVars <- factorVars[-which(factorVars %in% badFactors)]
      if(length(factorVars) == 0){ factorVars <- NULL }
      updateRunLog(paste0("\nThe following categorical response variables were removed from consideration\n",
                            "because they had only one level: ",paste(badFactors, collapse=","),"\n"))
    }
  } else { 
    badFactors <- NULL
    }
} else { 
  factorVars <- NULL
  badFactors <- NULL
  }


# model family 
# if response column contains only 1's and 0's response = presAbs
if(max(fieldDataSheet$Response)>1){
  modelFamily <-"poisson" 
} else { modelFamily <- "binomial" }

# Ignore background data if present
siteData <- siteData[!siteData$Response == -9999,]

# update response for pseudo-absence sites
siteData$Response[siteData$Response == -9998] <- 0

# prep deviance explained data
covData <- select(siteData, -Response)
devExp <- vector()
for(i in (1:ncol(covData))){
  devExp[i] <- try(my.panel.smooth(x = covData[,i], 
                                   y = siteData$Response,
                                   plot.it=FALSE,
                                   family=modelFamily),silent=TRUE)
}
devExp <- round(devExp,2)
devInfo <- as.data.frame(devExp)
devInfo$covs <- names(covData)
devInfo$covDE <- paste0(devInfo$covs, " (", devInfo$devExp, ")")
covsDE <- devInfo$covs
names(covsDE) <- devInfo$covDE

# run pairs explore with all variables -----------------------------------------

options <- covariateSelectionSheet
options$NumberOfPlots <- ncol(select(siteData, -Response, -all_of(badFactors)))

pairsExplore(inputData = siteData,
             options = options,
             selectedCovs = names(select(siteData, -Response, -all_of(badFactors))),
             factorVars = factorVars,
             family = modelFamily,
             outputFile = file.path(ssimTempDir, "InitialCovariateCorrelationMatrix.png"))

# run shiny app ----------------------------------------------------------------

# inputs
covData <- select(siteData, -Response, -all_of(badFactors))
SelectedCovariates <- names(covData)
# covsDE
options <- covariateSelectionSheet

# TO DO: find better way to access default web app 
browser.path <- NULL
if(file.exists("C:/Program Files/Google/Chrome/Application/chrome.exe")){
 browser.path <- "C:/Program Files/Google/Chrome/Application/chrome.exe"
} else if(file.exists("C:/Program Files(x86)/Google/Chrome/Application/chrome.exe")){
  browser.path <- "C:/Program Files(x86)/Google/Chrome/Application/chrome.exe"
} else if(file.exists("C:/Program Files/Mozilla Firefox/firefox.exe")){
  browser.path <- "C:/Program Files/Mozilla Firefox/firefox.exe"
 # } else if(file.exists("C:/Program Files/Internet Explorer/iexplore.exe")){
 # browser.path <- "C:/Program Files/Internet Explorer/iexplore.exe"
}

# portable chrome - to large to store on git 
# browser.path = file.path(packageDir,"Apps/chrome/chrome.exe")

if(is.null(browser.path)){
  runApp(appDir = file.path(packageDir, "04-covariate-correlation-app.R"),
         launch.browser = TRUE)  
} else {
  runApp(appDir = file.path(packageDir, "04-covariate-correlation-app.R"),
       launch.browser = function(shinyurl) {
         system(paste0("\"", browser.path, "\" --app=", shinyurl, " -incognito"), wait = F)
        })
}


# save reduced covariate list and image file -----------------------------------

reducedCovariatesSheet <- data.frame(CovariatesID = SelectedCovariates)
saveDatasheet(myScenario, reducedCovariatesSheet, "wisdm_ReducedCovariates")

covariateCorrelationSheet <- addRow(covariateCorrelationSheet, data.frame(InitialMatrix = file.path(ssimTempDir, "InitialCovariateCorrelationMatrix.png"), 
                                                                          SelectedMatrix = file.path(ssimTempDir, "SelectedCovariateCorrelationMatrix.png")))
saveDatasheet(myScenario, covariateCorrelationSheet, "wisdm_CovariateCorrelationMatrix")
