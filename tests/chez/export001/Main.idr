module Main

exportedBar : Int
exportedBar = 42

%export "chez:exportedFoo"
exportedFoo : Int -> Int
exportedFoo x = x + exportedBar

main : IO ()
main = pure ()

