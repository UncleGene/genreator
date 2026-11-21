-- Menu entry: Library > Plug-in Extras > Genreator > Reclassify Selected Photos
-- Ignores existing review state. Overwrites the model's fields; never removes a genre keyword
-- (docs/workflow.md).
local Classifier = require 'GrClassifier'
Classifier.classifySelection { reclassify = true }
