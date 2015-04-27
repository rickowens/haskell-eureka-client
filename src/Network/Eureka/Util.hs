module Network.Eureka.Util (parseUrlWithAdded) where

import Data.Maybe (fromJust)
import Network.HTTP.Client (Request, parseUrl)


parseUrlWithAdded :: String -> String -> Request
parseUrlWithAdded url = fromJust . parseUrl . addPath url

-- | Add an additional path fragment to a base URL.
--
-- I tried doing this using the http-types library but it was just so
-- inconvenient that I fell back to doing it this way. Alternative
-- implementations welcomed.
addPath :: String -> String -> String
addPath base additional = baseWithSlash ++ additional
  where
    baseWithSlash = if last base == '/' then base else base ++ "/"


