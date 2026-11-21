-- Menu entry: Library > Plug-in Extras > Genreator > Classify Selected Photos
local Classifier = require 'GrClassifier'
Classifier.classifySelection { reclassify = false }
